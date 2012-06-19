require File.dirname(__FILE__) + '/acts_as_cached/config'
require File.dirname(__FILE__) + '/acts_as_cached/cache_methods'
# require File.dirname(__FILE__) + '/acts_as_cached/benchmarking'
require File.dirname(__FILE__) + '/acts_as_cached/disabled'
require File.dirname(__FILE__) + '/acts_as_cached/railtie' if defined?(Rails::Railtie)

module ActsAsCached
  @@config = {}
  mattr_reader :config

  def self.config=(options)
    @@config = Config.setup options
  end

  def self.skip_cache_gets=(boolean)
    ActsAsCached.config[:skip_gets] = boolean
  end

  module Mixin
    def acts_as_cached(options = {})
      extend  ClassMethods
      include InstanceMethods

      extend  Extensions::ClassMethods    if defined? Extensions::ClassMethods
      include Extensions::InstanceMethods if defined? Extensions::InstanceMethods

      options.symbolize_keys!

      options[:store] ||= ActsAsCached.config[:store]
      options[:ttl]   ||= ActsAsCached.config[:ttl]

      # convert the find_by shorthand
      if find_by = options.delete(:find_by)
        options[:finder]   = "find_by_#{find_by}".to_sym
        options[:cache_id] = find_by
        create_cache_methods_for(find_by, false)
      end
      
      slugs_key = options.delete(:slugs_key)
      slugs_key = true if slugs_key.nil?

      # initialize caches_by options
      fields = options.delete(:caches_by) || []
      fields = [fields] unless fields.is_a?(Array)
      fields.each { |field| create_cache_methods_for(field, slugs_key) }

      # set up the automatic cache clearing if it is an AR model
      if respond_to?(:after_save)
        create_expire_cache_method([fields, find_by].flatten)
        after_save(:our_expire_cache)
        after_destroy(:our_expire_cache) if respond_to?(:after_destroy)
      end

      cache_config.replace  options.reject { |key,| not Config.valued_keys.include? key }
      cache_options.replace options.reject { |key,| Config.valued_keys.include? key }

      Disabled.add_to self and return if ActsAsCached.config[:disabled]
      # Benchmarking.add_to self if ActsAsCached.config[:benchmarking]
    end
    
    def create_expire_cache_method(fields)
      define_method(:our_expire_cache) do |*args|
        return unless self.changed? || (args.last && args.last[:force])
        # clear the default, by_id cache
        self.expire_cache
        # clear the other :caches_by caches
        fields.each do |field|
          find_method = "find_by_#{field}".to_sym
          values = field.to_s.split('_and_').map { |f| self.send(f.to_sym) }
          self.class.clear_cached_method(find_method, :with => values)
        end
        # call the "expire_custom_cache" method, if it exists
        self.send(:expire_custom_cache) if (self.respond_to?(:expire_custom_cache) || self.private_methods.include?('expire_custom_cache'))
        true
      end
    end

    def create_cache_methods_for(field, slugs_key)
      get_method = "get_by_#{field}".to_sym
      find_method = "find_by_#{field}".to_sym
      (class << self; self; end).instance_eval do
        define_method(get_method) do |*values|
          options = values.extract_options!
          field_names = field.to_s.split('_and_').map { |f| f.to_sym }
          raise(ArgumentError, "Wrong number of arguments (#{values.length} for #{field_names.length})") unless field_names.length == values.length
          # tweak the arguments. de-slug key arguments, turn id args into ints
          field_names.each_with_index do |f, i|
            case
            when (slugs_key && (f == :key) && values[i].is_a?(String))
              values[i] = values[i].gsub(/\-.*/, '')
            when ((f == :id) || (f.to_s.ends_with?('_id')))
              values[i] = values[i].to_i
            end
          end
          cached_method(find_method, options.merge(:with => values))
        end
      end
    end
  end

  class CacheException < StandardError; end
  class NoCacheStore   < CacheException; end
  class NoGetMulti     < CacheException; end
end

Rails::Application.initializer("cache_fu") do
  Object.send :include, ActsAsCached::Mixin
  unless File.exists?(config_file = Rails.root.join('config', 'memcached.yml'))
    error = "No config file found. If you used plugin version make sure you used `script/plugin install' or `rake memcached:cache_fu_install' if gem version and have memcached.yml in your config directory."
    puts error
    logger.error error
    exit!
  end
  ActsAsCached.config = YAML.load(ERB.new(IO.read(config_file)).result)
end
