# Test helper for Pasto::Cache specs
require "file_utils"
require "../src/pasto-cache"

# Set up test cache directory
TEST_CACHE_DIR = "./test_cache_output"

# Clean up test cache directory before each test
def setup_test_cache
  # Clear in-memory metadata
  Pasto::Cache.metadata.clear

  # Clear cache configs to avoid test pollution
  Pasto::Cache.cache_configs.clear

  # Clean up any existing test cache directory
  if Dir.exists?(TEST_CACHE_DIR)
    FileUtils.rm_rf(TEST_CACHE_DIR)
  end

  # Create fresh test cache directory
  Dir.mkdir_p(TEST_CACHE_DIR)
  Pasto::Cache.cache_dir = TEST_CACHE_DIR
end

# Clean up test cache directory after tests
def cleanup_test_cache
  if Dir.exists?(TEST_CACHE_DIR)
    FileUtils.rm_rf(TEST_CACHE_DIR)
  end
end

# Helper to create test headers
def test_headers
  {
    "Cache-Control"   => "public, max-age=3600",
    "X-Custom-Header" => "test-value",
    "Content-Type"    => "application/json",
  }
end

# Helper to create test content
def test_content(size = 100)
  ("x" * size).to_s
end

# Helper to count body files in cache dir
def count_body_files
  pattern = File.join(TEST_CACHE_DIR, "*.body")
  Dir.glob(pattern).size
end

# Helper to check if body file exists
def body_file_exists?(key)
  body_path = File.join(TEST_CACHE_DIR, "#{key}.body")
  File.exists?(body_path)
end

# Helper to read body file directly
def read_body_file(key)
  body_path = File.join(TEST_CACHE_DIR, "#{key}.body")
  File.read(body_path)
end
