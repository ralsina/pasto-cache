require "json"
require "kemal"

# Middleware for Pasto caching system
module PastoCache
  # Class variable to store original output objects for caching middleware
  @@original_outputs = {} of UInt64 => IO

  # Check if request contains Cache-Control directive
  private def self.cache_control_directive?(env, directive : String) : Bool
    cache_control = env.request.headers["Cache-Control"]?
    return false unless cache_control

    # Parse Cache-Control header (can be comma-separated list)
    directives = cache_control.downcase.split(',').map(&.strip)
    directives.includes?(directive.downcase)
  end

  # Handles cache check and response buffer setup before request processing
  #
  # This function should be called in a before_all block.
  # Returns cached metadata if found, otherwise sets up response capture.
  def self.handle_before_request(env) : Pasto::CacheMetadata?
    return nil unless cache_config = Pasto::Cache.find_cache_config(env.request.path)

    # Respect client's Cache-Control: no-cache directive
    if cache_control_directive?(env, "no-cache")
      # Bypass cache, don't even look up cached response
      return nil
    end

    cache_key = Pasto::Cache.generate_cache_key(env)

    # Check if we have a cached response (metadata from memory, very fast)
    if metadata = Pasto::Cache.get(cache_key)
      return metadata
    end

    # Set up response capture for this request
    setup_response_capture(env, cache_key, cache_config)
    nil
  end

  # Handles cache storage and response restoration after request processing
  #
  # This function should be called in an after_all block.
  # Caches the response content if successful and restores the original output.
  def self.handle_after_request(env)
    return unless original_output_id = env.get?("original_output_id")

    cache_key_str = env.get?("cache_key").to_s
    return if cache_key_str.empty?

    # Extract cache parameters
    mime_type = env.get?("cache_mime_type").to_s
    ttl_val = env.get?("cache_ttl")
    ttl = ttl_val ? ttl_val.to_s.to_i : nil

    # Get the response buffer (current response output)
    response_buffer = env.response.output
    return unless response_buffer

    # Read the captured content
    content = response_buffer.to_s

    # Capture response headers for caching
    headers = Hash(String, String).new
    env.response.headers.each do |key, value|
      case value
      when Array
        headers[key] = value.join(", ") # Join array values with comma
      else
        headers[key] = value.to_s # Convert single values to strings
      end
    end

    # Respect client's Cache-Control: no-store directive
    if cache_control_directive?(env, "no-store")
      # Don't cache this response, skip storage
      restore_original_output(env, original_output_id.to_s, content)
      return
    end

    # Cache successful responses with headers
    if env.response.status_code == 200
      Pasto::Cache.set(cache_key_str, content, mime_type, ttl, headers)
    end

    # Restore original output and write the buffer content
    restore_original_output(env, original_output_id.to_s, content)
  end

  # Sets up response capture by replacing the output with a memory buffer
  private def self.setup_response_capture(env, cache_key : String, cache_config)
    # Replace response IO with memory buffer to capture content
    response_buffer = IO::Memory.new
    original_output = env.response.output

    # Store original output in class variable to keep it alive
    @@original_outputs[original_output.object_id] = original_output

    # Store cache context in environment
    env.set("original_output_id", original_output.object_id.to_s)
    env.set("cache_key", cache_key)
    env.set("cache_mime_type", cache_config.mime_type)
    env.set("cache_ttl", cache_config.ttl)

    # Replace the response output with our buffer
    env.response.output = response_buffer
  end

  # Restores the original response output and writes the captured content
  private def self.restore_original_output(env, original_output_id : String, content : String)
    original_output_id_int = original_output_id.to_u64
    return unless original_io = @@original_outputs[original_output_id_int]?

    # Restore original output and write the buffer content
    env.response.output = original_io
    env.response.print(content)

    # Clean up the class variable
    @@original_outputs.delete(original_output_id_int)
  end

  # Convenience method for setting up the full middleware
  #
  # Usage:
  #   PastoCache.add_cache_middleware
  #
  # This is equivalent to:
  #   before_all { |env|
  #     if metadata = PastoCache.handle_before_request(env)
  #       # Serve from cache (metadata from memory, body from memory or disk)
  #     end
  #   }
  #   after_all { |env| PastoCache.handle_after_request(env) }
  def self.add_cache_middleware
    before_all do |env|
      if metadata = handle_before_request(env)
        threshold = Pasto::Cache.sendfile_threshold

        # Generate cache key (same as in handle_before_request)
        cache_key = Pasto::Cache.generate_cache_key(env)

        # Set content type and headers
        env.response.content_type = metadata.mime_type

        # Restore cached headers
        metadata.headers.each do |key, value|
          env.response.headers[key] = value
        end

        # Decide how to serve the response based on size
        if metadata.body_size >= threshold && File.exists?(metadata.body_path)
          # Large response: use send_file for zero-copy disk -> socket transfer
          send_file env, metadata.body_path
        else
          # Small response: load into memory and send
          if body_content = Pasto::Cache.get_body(cache_key)
            halt env, 200, body_content
          else
            # Body file missing, treat as cache miss
            env.response.status_code = 503
            "Cache error: body file missing"
          end
        end
      end
    end

    after_all do |env|
      handle_after_request(env)
    end
  end
end
