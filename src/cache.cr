require "file_utils"
require "json"

# Cache management for Pasto application
module Pasto
  # Cache metadata (stored in memory, separate from body)
  class CacheMetadata
    property mime_type : String
    property created_at : Time
    property ttl : Int32?                   # Time to live in seconds, nil means no expiration
    property headers : Hash(String, String) # Store response headers
    property body_path : String             # Path to body file on disk
    property body_size : Int64              # Size of body file in bytes

    def initialize(@mime_type : String, @ttl : Int32?, @headers : Hash(String, String), @body_path : String, @body_size : Int64)
      @created_at = Time.utc
    end

    def expired? : Bool
      return false unless ttl_val = ttl
      (Time.utc - @created_at).total_seconds > ttl_val
    end
  end

  # Cache entry with content (legacy, kept for backwards compatibility)
  class CacheEntry
    property content : String
    property mime_type : String
    property created_at : Time
    property ttl : Int32?                   # Time to live in seconds, nil means no expiration
    property headers : Hash(String, String) # Store response headers

    def initialize(@content : String, @mime_type : String, @ttl : Int32? = nil, @headers : Hash(String, String) = Hash(String, String).new)
      @created_at = Time.utc
    end

    def expired? : Bool
      return false unless ttl_val = ttl
      (Time.utc - @created_at).total_seconds > ttl_val
    end

    def to_json : String
      {
        content:    @content,
        mime_type:  @mime_type,
        created_at: @created_at.to_unix,
        ttl:        @ttl,
        headers:    @headers,
      }.to_json
    end

    def self.from_json(json : String) : CacheEntry
      data = Hash(String, JSON::Any).from_json(json)
      content = data["content"].as_s
      mime_type = data["mime_type"].as_s
      created_at = Time.unix(data["created_at"].as_i)
      ttl = data["ttl"]?.try(&.as_i?)

      # Parse headers
      headers = Hash(String, String).new
      if headers_data = data["headers"]?
        headers_data.as_h.each do |key, value|
          headers[key] = value.as_s
        end
      end

      entry = CacheEntry.new(content, mime_type, ttl, headers)
      entry.created_at = created_at
      entry
    end
  end

  # Cache configuration for endpoints
  struct CacheConfig
    property path_regex : Regex
    property mime_type : String
    property ttl : Int32?

    def initialize(@path_regex : Regex, @mime_type : String, @ttl : Int32? = nil)
    end
  end

  class Cache
    @@cache_dir : String = "./public/cache"
    @@cache_configs = [] of CacheConfig
    @@metadata = Hash(String, CacheMetadata).new
    @@sendfile_threshold : Int64 = 16384 # 16KB default

    def self.cache_dir=(dir : String)
      @@cache_dir = dir
    end

    def self.cache_dir
      @@cache_dir
    end

    def self.cache_configs
      @@cache_configs
    end

    def self.metadata
      @@metadata
    end

    def self.sendfile_threshold=(threshold : Int32)
      @@sendfile_threshold = threshold.to_i64
    end

    def self.sendfile_threshold
      @@sendfile_threshold
    end

    def self.add_cache_config(path_regex : Regex, mime_type : String, ttl : Int32? = nil)
      @@cache_configs << CacheConfig.new(path_regex, mime_type, ttl)
    end

    def self.find_cache_config(path : String) : CacheConfig?
      @@cache_configs.find(&.path_regex.matches?(path))
    end

    # Get cache metadata from memory (fast, no disk I/O)
    def self.get(key : String) : CacheMetadata?
      metadata = @@metadata[key]?
      return nil unless metadata
      return nil if metadata.expired?

      # Verify body file still exists
      unless File.exists?(metadata.body_path)
        # Body file missing, remove metadata and treat as cache miss
        @@metadata.delete(key)
        return nil
      end

      metadata
    end

    # Get cached body content from disk
    def self.get_body(key : String) : String?
      metadata = @@metadata[key]?
      return nil unless metadata

      body_path = metadata.body_path
      return nil unless File.exists?(body_path)

      begin
        File.read(body_path)
      rescue
        nil
      end
    end

    # Store response in cache (metadata in memory, body on disk)
    def self.set(key : String, content : String, mime_type : String, ttl : Int32? = nil, headers : Hash(String, String) = Hash(String, String).new) : Bool
      body_path = File.join(@@cache_dir, "#{key}.body")

      begin
        # Write body to disk (raw content, not JSON)
        File.write(body_path, content)
        body_size = content.bytesize.to_i64

        # Create and store metadata in memory
        metadata = CacheMetadata.new(mime_type, ttl, headers, body_path, body_size)
        @@metadata[key] = metadata

        true
      rescue
        false
      end
    end

    # Legacy method for backwards compatibility - now uses new storage format
    def self.get_legacy(key : String) : CacheEntry?
      file_path = File.join(@@cache_dir, "#{key}.cache")
      return nil unless File.exists?(file_path)

      begin
        json = File.read(file_path)
        entry = CacheEntry.from_json(json)
        return nil if entry.expired?
        entry
      rescue
        nil
      end
    end

    def self.invalidate(id : String) : Bool
      # Remove from metadata
      @@metadata.reject! { |k, _| k.starts_with?(id) }

      pattern = File.join(@@cache_dir, "#{id}*.cache")
      body_pattern = File.join(@@cache_dir, "#{id}*.body")

      begin
        # Delete old .cache files
        Dir.glob(pattern).each do |file|
          File.delete(file)
        end

        # Delete .body files
        Dir.glob(body_pattern).each do |file|
          File.delete(file)
        end

        true
      rescue
        false
      end
    end

    # Generate cache key from request
    def self.generate_cache_key(env) : String
      path = env.request.path
      method = env.request.method
      query = env.request.query_params.to_a.sort_by(&.first.[](0)).map { |k, v| "#{k}=#{v}" }.join("&")

      # Include request body hash for POST/PUT requests
      body_hash = ""
      if env.request.method.in?("POST", "PUT") && (request_body = env.request.body)
        body = request_body.gets_to_end
        body_hash = OpenSSL::Digest.new("sha256").update(body).final.hexstring[0..15]
        # Reset body for downstream handlers
        env.request.body = IO::Memory.new(body)
      end

      key_data = "#{method}:#{path}:#{query}:#{body_hash}"
      OpenSSL::Digest.new("sha256").update(key_data).final.hexstring
    end
  end

  # Initialize cache directory in the main app
  def self.init_cache(cache_dir : String)
    Cache.cache_dir = cache_dir
    Dir.mkdir_p(cache_dir)
  end
end
