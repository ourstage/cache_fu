require 'new_relic/agent/method_tracer'
module ActsAsCached
  module ClassMethods
    extend NewRelic::Agent::MethodTracer
    
    @@nil_sentinel = :_nil

    def cache_config
      config = ActsAsCached::Config.class_config[cache_name] ||= {}
      if name == cache_name
        config
      else
        # sti
        ActsAsCached::Config.class_config[name] ||= config.dup
      end
    end

    def cache_options
      cache_config[:options] ||= {}
    end
    
    def get_cache(*args)
      item = nil
      self.class.trace_execution_scoped(['CacheFu/get_cache']) do 
        options = args.last.is_a?(Hash) ? args.pop : {}
        args    = args.flatten
        cache_time = options[:ttl] || cache_config[:ttl] || 1500

        ##
        # head off to get_caches if we were passed multiple cache_ids
        return get_caches_as_list(args, options) if args.size > 1
      
        cache_id = args.first
        lock_cache_time = [(0.09 * cache_time).round, 3.seconds].max
        expiry_cache_id = "xpy_" + cache_id.to_s
      
        item = fetch_cache(cache_id)
        if item.nil? || (item.is_a?(Hash) && item[:value] == @@nil_sentinel)
          item = set_cache(cache_id, block_given? ? yield : fetch_cachable_data(cache_id), options[:ttl])
        else
          if item.is_a?(Hash) && item.has_key?(:exxpiry) && item.has_key?(:value)
            expiration_date = item[:exxpiry]
            item = item[:value]
          end
        
          item = nil if @@nil_sentinel == item
        
          if expiration_date.present? && Time.now.utc > expiration_date && cache_lock(cache_id, lock_cache_time)
            begin
              if block_given?
                item = set_cache(cache_id, yield, cache_time)
              elsif cache_id == cache_id.to_i
                fetched_data = fetch_cachable_data(cache_id)
                item = set_cache(cache_id, fetched_data, cache_time) unless fetched_data.blank?
              end 
            rescue Exception => ex
              item = nil
            end
            cache_unlock(cache_id)
          end
        end
      end
      item
    end

    ##
    # This method accepts an array of cache_ids which it will use to call
    # get_multi on your cache store.  Any misses will be fetched and saved to
    # the cache, and a hash keyed by cache_id will ultimately be returned.
    #
    # If your cache store does not support #get_multi an exception will be raised.
    def get_caches(*args)
      self.class.trace_execution_scoped(['CacheFu/get_caches']) do 
        raise NoGetMulti unless cache_store.respond_to? :get_multi

        options   = args.last.is_a?(Hash) ? args.pop : {}
        cache_ids = args.flatten.map(&:to_s)
        keys      = cache_keys(cache_ids)

        # Map memcache keys to object cache_ids in { memcache_key => object_id } format
        keys_map = Hash[*keys.zip(cache_ids.reject{|cid| cid.blank?}).flatten]

        # Call get_multi and figure out which keys were missed based on what was a hit
        hits = ActsAsCached.config[:disabled] ? {} : (cache_store(:get_multi, *keys) || {})

        # Misses can take the form of key => nil
        hits.delete_if { |key, value| value.nil? }

        misses = keys - hits.keys
        hits.each { |k, v| hits[k] = nil if v == @@nil_sentinel }
        hit_values = Hash[*hits.values.map{|h| [h[:value].id, h[:value]]}.flatten]

        # Return our hash if there are no misses
        return hit_values if misses.empty?

        # Find any missed records
        needed_ids     = keys_map.values_at(*misses)
        missed_records = Array(fetch_cachable_data(needed_ids))

        # Cache the missed records
        miss_values = {}
        missed_records.flatten.each do |missed_record|
          set_cache(missed_record.id.to_i, missed_record, options[:ttl])
          miss_values[missed_record.id] = missed_record
        end
      
        # Return all records as a hash indexed by object cache_id
        (hit_values.merge(miss_values))
      end
    end

    # simple wrapper for get_caches that
    # returns the items as an ordered array
    def get_caches_as_list(*args)
      self.class.trace_execution_scoped(['CacheFu/get_caches_as_list']) do 
        multi_result = []
        self.class.trace_execution_scoped(['CacheFu/multiget']) do 
          cache_ids = args.last.is_a?(Hash) ? args.first : args
          cache_ids = [cache_ids].flatten
          hash      = get_caches(*args)

          multi_result = cache_ids.map do |key|
            hash[key.to_i]
          end
        end
        multi_result
      end
    end
    
    def get(id)
      self.class.trace_execution_scoped(['CacheFu/get']) do 
        return nil if id.nil? || (id == 0)
        if id.is_a?(Array)
          return [] if id.blank?
          return [nil] if (id.length == 1) && ((id[0].nil?) || (id[0] == 0))
          get_caches_as_list(id) rescue []
        else
          get_cache(id.to_i) rescue nil
        end
      end
    end
    
    def set_cache(cache_id, value, ttl = nil)
      self.class.trace_execution_scoped(['CacheFu/set_cache']) do 
        value.tap do |v|
          v = @@nil_sentinel if v.nil?
        
          cache_time = ttl || cache_config[:ttl] || 1500
          raise ArgumentError.new("ttl must be <= 30.days") if cache_time > 30.days
          v = { :exxpiry => Time.now.utc + (0.8 * cache_time).round, :value => v } if cache_time > 5.seconds
      
          cache_store(:set, cache_key(cache_id), v, cache_time)
        end
      end
    end

    def expire_cache(cache_id = nil)
      self.class.trace_execution_scoped(['CacheFu/expire_cache']) do 
        cache_store(:delete, cache_key(cache_id))
        true
      end
    end
    alias :clear_cache :expire_cache

    def reset_cache(cache_id = nil)
      self.class.trace_execution_scoped(['CacheFu/reset_cache']) do 
        set_cache(cache_id, fetch_cachable_data(cache_id))
      end
    end

    ##
    # Encapsulates the pattern of writing custom cache methods
    # which do nothing but wrap custom finders.
    #
    #   => Story.caches(:find_popular)
    #
    #   is the same as
    #
    #   def self.cached_find_popular
    #     get_cache(:find_popular) { find_popular }
    #   end
    #
    #  The method also accepts both a :ttl and/or a :with key.
    #  Obviously the :ttl value controls how long this method will
    #  stay cached, while the :with key's value will be passed along
    #  to the method.  The hash of the :with key will be stored with the key,
    #  making two near-identical #caches calls with different :with values utilize
    #  different caches.
    #
    #  => Story.caches(:find_popular, :with => :today)
    #
    #  is the same as
    #
    #   def self.cached_find_popular
    #     get_cache("find_popular:today") { find_popular(:today) }
    #   end
    #
    # If your target method accepts multiple parameters, pass :withs an array.
    #
    # => Story.caches(:find_popular, :withs => [ :one, :two ])
    #
    # is the same as
    #
    #   def self.cached_find_popular
    #     get_cache("find_popular:onetwo") { find_popular(:one, :two) }
    #   end
    def caches(method, options = {})
      self.class.trace_execution_scoped(['CacheFu/caches']) do 
        if options.keys.include?(:with)
          with = options.delete(:with)
          get_cache("#{method}:#{with}", options) { send(method, with) }
        elsif withs = options.delete(:withs)
          get_cache("#{method}:#{withs}", options) { send(method, *withs) }
        else
          get_cache(method, options) { send(method) }
        end
      end
    end
    alias :cached :caches
    alias :cached_method :caches

    def clear_caches(method, options = {})
      self.class.trace_execution_scoped(['CacheFu/clear_caches']) do 
        if options.keys.include?(:with)
          with = options.delete(:with)
          clear_cache("#{method}:#{with}")
        elsif withs = options.delete(:withs)
          clear_cache("#{method}:#{withs}")
        else
          clear_cache(method)
        end
      end
    end
    alias :clear_cached_method :clear_caches

    def cached?(cache_id = nil)
      self.class.trace_execution_scoped(['CacheFu/cached?']) do 
        fetch_cache(cache_id).nil? ? false : true
      end
    end
    alias :is_cached? :cached?
    
   # Get a 5-second lock on another cache item
    def cache_lock(cache_id, lock_cache_time = 5.seconds)
      self.class.trace_execution_scoped(['CacheFu/cache_lock']) do 
        stored = cache_store(:add, "lck_" + cache_key(cache_id), 1, lock_cache_time)
        (stored =~ /^STORED/) != nil
      end
    end

    def cache_unlock(cache_id)
      self.class.trace_execution_scoped(['CacheFu/cache_unlock']) do 
        cache_store(:delete, "lck_" + cache_key(cache_id))
      end
    end
    
    def fetch_cache(cache_id)
      self.class.trace_execution_scoped(['CacheFu/fetch_cache']) do 
        return if ActsAsCached.config[:skip_gets]

        autoload_missing_constants do
          cache_store(:get, cache_key(cache_id))
        end
      end
    end

    def fetch_cachable_data(cache_id = nil)
      self.class.trace_execution_scoped(['CacheFu/fetch_cachable_data']) do 
        return nil if cache_id.is_a?(String) && cache_id.include?(':')

        finder = :find
        return send(finder) unless cache_id

        args = [cache_id].flatten
        args << cache_options.dup unless cache_options.blank?
        data = send(finder, *args) rescue nil
      end
    end

    def cache_namespace
      self.class.trace_execution_scoped(['CacheFu/cache_namespace']) do 
        cache_store.respond_to?(:namespace) ? cache_store(:namespace) : (CACHE.instance_variable_get('@options') && CACHE.instance_variable_get('@options')[:namespace])
      end
    end

    # Memcache-client automatically prepends the namespace, plus a colon, onto keys, so we take that into account for the max key length.
    # Rob Sanheim
    def max_key_length
      unless @max_key_length
        key_size = cache_config[:key_size] || 250
        @max_key_length = cache_namespace ? (key_size - cache_namespace.length - 1) : key_size
      end
      @max_key_length
    end

    def cache_name
      @cache_name ||= respond_to?(:base_class) ? base_class.name : name
    end

    def cache_keys(*cache_ids)
      self.class.trace_execution_scoped(['CacheFu/cache_keys']) do 
        cache_ids.flatten.map { |cache_id| cache_key(cache_id) }
      end
    end

    def cache_key(cache_id)
      self.class.trace_execution_scoped(['CacheFu/cache_key']) do 
        [cache_name, cache_config[:version], cache_id].compact.join(':').gsub(' ', '_')[0..(max_key_length - 1)]
      end
    end

    def cache_store(method = nil, *args)
      self.class.trace_execution_scoped(['CacheFu/cache_store']) do       
        return cache_config[:store] unless method

        load_constants = %w( get get_multi ).include? method.to_s

        swallow_or_raise_cache_errors(load_constants) do
          cache_config[:store].send(method, *args)
        end
      end
    end

    def swallow_or_raise_cache_errors(load_constants = false, &block)
      load_constants ? autoload_missing_constants(&block) : yield
    rescue TypeError => error
      if error.to_s.include? 'Proc'
        raise MarshalError, "Most likely an association callback defined with a Proc is triggered, see http://ar.rubyonrails.com/classes/ActiveRecord/Associations/ClassMethods.html (Association Callbacks) for details on converting this to a method based callback"
      else
        raise error
      end
    rescue Exception => error
      # do a retry for timeout errors since they shouldn't raise as exceptions
      tries ||= 1
      do_reset = error.message =~ /Broken pipe/i      # this happens if the memcached server is restarted while the app is running
      
      if tries < 2 && (do_reset || error.message == 'IO timeout')      # try a total of two times
        Rails.logger.debug "MemCache Error: #{error.message} (tries: #{tries}): " rescue nil
        tries += 1
        CACHE.reset if do_reset     # let's try to reconnect
        retry
      end
      if ActsAsCached.config[:raise_errors]
        raise error
      else
        Rails.logger.debug "MemCache Error: #{error.message}" rescue nil
        nil
      end
    end

    def autoload_missing_constants
      yield
    rescue ArgumentError, MemCache::MemCacheError => error
      lazy_load ||= Hash.new { |hash, hash_key| hash[hash_key] = true; false }
      if error.to_s[/undefined class|referred/] && !lazy_load[error.to_s.split.last.sub(/::$/, '').constantize] then retry
      else raise error end
    end
  end

  module InstanceMethods
    def self.included(base)
      base.send :delegate, :cache_config,  :to => 'self.class'
      base.send :delegate, :cache_options, :to => 'self.class'
    end

    def get_cache(key = nil, options = {}, &block)
      self.class.get_cache(cache_id(key), options, &block)
    end

    def set_cache(key, value, ttl = nil)
      self.class.set_cache(cache_id(key), value, ttl)
    end

    def reset_cache(key = nil)
      self.class.reset_cache(cache_id(key))
    end

    def expire_cache(key = nil)
      self.class.expire_cache(cache_id(key))
    end
    alias :clear_cache :expire_cache

    def cached?(key = nil)
      self.class.cached? cache_id(key)
    end

    def cache_key
      self.class.cache_key(cache_id)
    end

    def cache_id(key = nil)
      id = send(cache_config[:cache_id] || :id)
      key.nil? ? id : "#{id}:#{key}"
    end

    def caches(method, options = {})
      key = "#{id}:#{method}"
      if options.keys.include?(:with)
        with = options.delete(:with)
        self.class.get_cache("#{key}:#{with}", options) { send(method, with) }
      elsif withs = options.delete(:withs)
        self.class.get_cache("#{key}:#{withs}", options) { send(method, *withs) }
      else
        self.class.get_cache(key, options) { send(method) }
      end
    end
    alias :cached :caches
    alias :cached_method :caches
    
    def clear_caches(method, options = {})
      if options.keys.include?(:with)
        with = options.delete(:with)
        clear_cache("#{method}:#{with}", options) { send(method, with) }
      elsif withs = options.delete(:withs)
        clear_cache("#{method}:#{withs}", options) { send(method, *withs) }
      else
        clear_cache(method, options) { send(method) }
      end
    end
    alias :clear_cached_method :clear_caches

    # Ryan King
    def set_cache_with_associations
      Array(cache_options[:include]).each do |assoc|
        send(assoc).reload
      end if cache_options[:include]
      set_cache
    end

    # Lourens Naud
    def expire_cache_with_associations(*associations_to_sweep)
      (Array(cache_options[:include]) + associations_to_sweep).flatten.uniq.compact.each do |assoc|
        Array(send(assoc)).compact.each { |item| item.expire_cache if item.respond_to?(:expire_cache) }
      end
      expire_cache
    end
  end

  class MarshalError < StandardError; end
  class MemCache; end
  class MemCache::MemCacheError < StandardError; end
end
