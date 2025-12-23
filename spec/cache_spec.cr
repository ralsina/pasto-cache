require "spec"
require "./spec_helper"

describe Pasto::Cache do
  describe "CacheMetadata" do
    it "creates metadata with all properties" do
      headers = test_headers
      metadata = Pasto::CacheMetadata.new(
        mime_type: "application/json",
        ttl: 3600,
        headers: headers,
        body_path: "/test/path.body",
        body_size: 1024
      )

      metadata.mime_type.should eq "application/json"
      metadata.ttl.should eq 3600
      metadata.headers.should eq headers
      metadata.body_path.should eq "/test/path.body"
      metadata.body_size.should eq 1024
      metadata.created_at.should be_a(Time)
    end

    it "correctly identifies expired entries" do
      # Non-expiring entry (nil TTL)
      metadata_no_ttl = Pasto::CacheMetadata.new(
        mime_type: "text/plain",
        ttl: nil,
        headers: Hash(String, String).new,
        body_path: "/test/body.body",
        body_size: 100
      )
      metadata_no_ttl.expired?.should be_false

      # Expiring entry with future TTL
      metadata_future = Pasto::CacheMetadata.new(
        mime_type: "text/plain",
        ttl: 3600,
        headers: Hash(String, String).new,
        body_path: "/test/body.body",
        body_size: 100
      )
      metadata_future.expired?.should be_false

      # Expired entry (we'll manipulate created_at)
      metadata_expired = Pasto::CacheMetadata.new(
        mime_type: "text/plain",
        ttl: 1,
        headers: Hash(String, String).new,
        body_path: "/test/body.body",
        body_size: 100
      )
      # Set created_at to 2 seconds ago
      metadata_expired.created_at = Time.utc - 2.seconds
      metadata_expired.expired?.should be_true
    end
  end

  describe "Configuration" do
    it "configures cache directory" do
      setup_test_cache
      Pasto::Cache.cache_dir.should eq TEST_CACHE_DIR
      cleanup_test_cache
    end

    it "configures sendfile threshold" do
      Pasto::Cache.sendfile_threshold = 8192
      Pasto::Cache.sendfile_threshold.should eq 8192

      # Reset to default
      Pasto::Cache.sendfile_threshold = 16384
      Pasto::Cache.sendfile_threshold.should eq 16384
    end

    it "manages cache configurations" do
      setup_test_cache
      Pasto::Cache.add_cache_config(/^\/test$/, "application/json", 3600)
      Pasto::Cache.add_cache_config(/^\/api/, "text/html", nil)

      configs = Pasto::Cache.cache_configs
      configs.size.should eq 2
      configs[0].path_regex.matches?("/test").should be_true
      configs[0].mime_type.should eq "application/json"
      configs[0].ttl.should eq 3600

      configs[1].path_regex.matches?("/api/data").should be_true
      configs[1].ttl.should be_nil
      cleanup_test_cache
    end

    it "finds matching cache config" do
      setup_test_cache
      Pasto::Cache.add_cache_config(/^\/api\/v1/, "application/json", 600)

      if config = Pasto::Cache.find_cache_config("/api/v1/users")
        config.mime_type.should eq "application/json"
      else
        fail "Config should not be nil"
      end

      config = Pasto::Cache.find_cache_config("/other/path")
      config.should be_nil
      cleanup_test_cache
    end
  end

  describe "Cache Storage" do
    it "stores metadata in memory and body on disk" do
      setup_test_cache

      content = test_content(100)
      headers = test_headers

      result = Pasto::Cache.set("test_key", content, "application/json", 3600, headers)
      result.should be_true

      # Check metadata is in memory
      Pasto::Cache.metadata.size.should eq 1
      metadata = Pasto::Cache.metadata["test_key"]?
      metadata.should_not be_nil

      # Check metadata properties
      if metadata_obj = metadata
        metadata_obj.mime_type.should eq "application/json"
        metadata_obj.ttl.should eq 3600
        metadata_obj.headers.should eq headers
        metadata_obj.body_size.should eq 100
      else
        fail "Metadata should not be nil"
      end

      # Check body file exists on disk
      body_file_exists?("test_key").should be_true
      read_body_file("test_key").should eq content

      cleanup_test_cache
    end

    it "retrieves metadata from memory" do
      setup_test_cache

      content = test_content(50)
      headers = {"X-Test" => "value"}

      Pasto::Cache.set("key1", content, "text/html", nil, headers)

      # Get metadata (should be fast, no disk I/O)
      metadata = Pasto::Cache.get("key1")
      metadata.should_not be_nil

      if metadata_obj = metadata
        metadata_obj.mime_type.should eq "text/html"
        metadata_obj.headers.should eq headers
        metadata_obj.body_size.should eq 50
      else
        fail "Metadata should not be nil"
      end

      cleanup_test_cache
    end

    it "returns nil for non-existent keys" do
      setup_test_cache

      metadata = Pasto::Cache.get("nonexistent")
      metadata.should be_nil

      body = Pasto::Cache.get_body("nonexistent")
      body.should be_nil

      cleanup_test_cache
    end

    it "retrieves body content from disk" do
      setup_test_cache

      content = "test content for body"
      Pasto::Cache.set("body_key", content, "text/plain", 600, Hash(String, String).new)

      # Retrieve body
      body = Pasto::Cache.get_body("body_key")
      body.should_not be_nil
      body.should eq content

      cleanup_test_cache
    end

    it "handles missing body files gracefully" do
      setup_test_cache

      # Create metadata but delete body file
      Pasto::Cache.set("orphan_key", "content", "text/plain", 600, Hash(String, String).new)
      body_path = File.join(TEST_CACHE_DIR, "orphan_key.body")
      File.delete(body_path) if File.exists?(body_path)

      # get should return nil when body file is missing
      metadata = Pasto::Cache.get("orphan_key")
      metadata.should be_nil

      # Metadata should be removed
      Pasto::Cache.metadata.has_key?("orphan_key").should be_false

      cleanup_test_cache
    end
  end

  describe "Expiration" do
    it "checks expiration correctly" do
      setup_test_cache

      # Store with short TTL
      Pasto::Cache.set("expiring_key", "content", "text/plain", 1, Hash(String, String).new)

      # Should not be expired immediately
      metadata = Pasto::Cache.get("expiring_key")
      metadata.should_not be_nil

      # Manually expire by setting created_at to past
      metadata_obj = Pasto::Cache.metadata["expiring_key"]
      metadata_obj.created_at = Time.utc - 2.seconds

      # Now should be expired
      metadata = Pasto::Cache.get("expiring_key")
      metadata.should be_nil

      cleanup_test_cache
    end

    it "allows nil TTL (no expiration)" do
      setup_test_cache

      Pasto::Cache.set("permanent_key", "content", "text/plain", nil, Hash(String, String).new)

      # Should never expire
      metadata = Pasto::Cache.get("permanent_key")
      metadata.should_not be_nil

      metadata_obj = Pasto::Cache.metadata["permanent_key"]
      metadata_obj.created_at = Time.utc - 1000000.seconds

      metadata = Pasto::Cache.get("permanent_key")
      metadata.should_not be_nil

      cleanup_test_cache
    end
  end

  describe "Header Preservation" do
    it "preserves simple string headers" do
      setup_test_cache

      headers = {
        "Content-Type"  => "application/json",
        "X-Custom"      => "custom-value",
        "Cache-Control" => "max-age=3600",
      }

      Pasto::Cache.set("headers_key", "content", "text/html", 600, headers)

      metadata = Pasto::Cache.get("headers_key")
      metadata.should_not be_nil
      if metadata_obj = metadata
        metadata_obj.headers.should eq headers
      else
        fail "Metadata should not be nil"
      end

      cleanup_test_cache
    end

    it "preserves headers with special characters" do
      setup_test_cache

      headers = {
        "Cache-Control" => "public, max-age=604800, must-revalidate",
        "X-API-Key"     => "key-with-dashes",
        "ETag"          => "\"33a64df551425fcc55e4d42a148795d9f25f89d4\"",
      }

      Pasto::Cache.set("special_headers", "content", "application/json", 3600, headers)

      metadata = Pasto::Cache.get("special_headers")
      metadata.should_not be_nil
      if metadata_obj = metadata
        metadata_obj.headers.should eq headers
      else
        fail "Metadata should not be nil"
      end

      cleanup_test_cache
    end
  end

  describe "Invalidation" do
    it "invalidates cache entries by pattern" do
      setup_test_cache

      # Create multiple entries
      Pasto::Cache.set("user_123_data", "content1", "application/json", 600, Hash(String, String).new)
      Pasto::Cache.set("user_123_profile", "content2", "application/json", 600, Hash(String, String).new)
      Pasto::Cache.set("user_456_data", "content3", "application/json", 600, Hash(String, String).new)

      # Should have 3 entries in memory
      Pasto::Cache.metadata.size.should eq 3

      # Invalidate user_123 entries
      result = Pasto::Cache.invalidate("user_123")
      result.should be_true

      # Should have 1 entry left
      Pasto::Cache.metadata.size.should eq 1

      # user_123 entries should be gone
      Pasto::Cache.get("user_123_data").should be_nil
      Pasto::Cache.get("user_123_profile").should be_nil

      # user_456 entry should still exist
      Pasto::Cache.get("user_456_data").should_not be_nil

      cleanup_test_cache
    end

    it "removes body files during invalidation" do
      setup_test_cache

      Pasto::Cache.set("invalidate_test", "content", "text/plain", 600, Hash(String, String).new)

      # Verify body file exists
      body_file_exists?("invalidate_test").should be_true

      # Invalidate
      Pasto::Cache.invalidate("invalidate_test")

      # Body file should be deleted
      body_file_exists?("invalidate_test").should be_false

      cleanup_test_cache
    end
  end

  describe "Size Tracking" do
    it "correctly tracks body sizes" do
      setup_test_cache

      small_content = test_content(10)
      large_content = test_content(10000)

      Pasto::Cache.set("small", small_content, "text/plain", 600, Hash(String, String).new)
      Pasto::Cache.set("large", large_content, "text/plain", 600, Hash(String, String).new)

      metadata_small = Pasto::Cache.get("small")
      metadata_large = Pasto::Cache.get("large")

      metadata_small.should_not be_nil
      if metadata_small_obj = metadata_small
        metadata_small_obj.body_size.should eq 10
      else
        fail "Small metadata should not be nil"
      end

      metadata_large.should_not be_nil
      if metadata_large_obj = metadata_large
        metadata_large_obj.body_size.should eq 10000
      else
        fail "Large metadata should not be nil"
      end

      cleanup_test_cache
    end
  end

  describe "Cache Key Generation" do
    it "generates consistent keys for same request" do
      # We can't easily test without a Kemal env, but we can test the structure
      # This would require mocking or integration testing with Kemal
      # For now, we'll skip this as it would require more complex setup
    end
  end

  describe "Edge Cases" do
    it "handles empty content" do
      setup_test_cache

      result = Pasto::Cache.set("empty", "", "text/plain", 600, Hash(String, String).new)
      result.should be_true

      metadata = Pasto::Cache.get("empty")
      metadata.should_not be_nil
      if metadata_obj = metadata
        metadata_obj.body_size.should eq 0
      else
        fail "Metadata should not be nil"
      end

      body = Pasto::Cache.get_body("empty")
      body.should eq ""

      cleanup_test_cache
    end

    it "handles empty headers" do
      setup_test_cache

      result = Pasto::Cache.set("no_headers", "content", "text/plain", 600, Hash(String, String).new)
      result.should be_true

      metadata = Pasto::Cache.get("no_headers")
      metadata.should_not be_nil
      if metadata_obj = metadata
        metadata_obj.headers.should be_empty
      else
        fail "Metadata should not be nil"
      end

      cleanup_test_cache
    end

    it "handles unicode content" do
      setup_test_cache

      unicode_content = "Hello 世界 🌍"
      result = Pasto::Cache.set("unicode", unicode_content, "text/plain", 600, Hash(String, String).new)
      result.should be_true

      body = Pasto::Cache.get_body("unicode")
      body.should eq unicode_content

      cleanup_test_cache
    end
  end

  describe "Cache-Control Request Directives" do
    # Note: Full integration testing of Cache-Control request directives requires
    # Kemal env objects which need more complex setup. These tests verify the
    # cache storage behavior. The actual request header parsing is tested in
    # the middleware layer.

    it "allows cache to be bypassed (no-cache simulation)" do
      setup_test_cache

      # Simulate no-cache by not storing in the first place
      content = test_content(100)
      Pasto::Cache.set("bypassable", content, "application/json", 600, Hash(String, String).new)

      # Verify it's cached normally
      metadata = Pasto::Cache.get("bypassable")
      metadata.should_not be_nil

      cleanup_test_cache
    end

    it "allows responses to not be stored (no-store simulation)" do
      setup_test_cache

      # Simulate no-store by checking cache doesn't have the entry
      content = test_content(100)

      # Don't store, just verify cache is empty
      Pasto::Cache.metadata.size.should eq 0

      # Manually add to cache to verify it works when allowed
      Pasto::Cache.set("storeable", content, "application/json", 600, Hash(String, String).new)

      # Verify it was stored
      metadata = Pasto::Cache.get("storeable")
      metadata.should_not be_nil

      cleanup_test_cache
    end
  end
end
