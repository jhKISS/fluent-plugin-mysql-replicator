module Fluent
  class MysqlReplicatorMultiInput < Fluent::Input
    Plugin.register_input('mysql_replicator_multi', self)

    def initialize
      require 'mysql2'
      require 'digest/sha1'
      super
    end

    config_param :manager_host, :string, :default => 'localhost'
    config_param :manager_port, :integer, :default => 3306
    config_param :manager_username, :string, :default => nil
    config_param :manager_password, :string, :default => ''
    config_param :manager_database, :string, :default => 'replicator_manager'
    config_param :tag, :string, :default => nil

    config_param :bulk_insert_count, :integer, :default => 50
    config_param :bulk_insert_timeout, :integer, :default => 10

    def configure(conf)
      super
      @reconnect_interval = Config.time_value('10sec')
      if @tag.nil?
        raise Fluent::ConfigError, "mysql_replicator_multi: missing 'tag' parameter. Please add following line into config like 'tag replicator.${name}.${event}.${primary_key}'"
      end
    end

    def start
      begin
        @threads = []
        @mutex = Mutex.new
        @manager_db = get_manager_connection
        @manager_db.query("SET SESSION wait_timeout=1800;")
        @threads << Thread.new {
          @hash_table_bulk_insert = []
          @hash_table_bulk_insert_last_time = Time.now
          hash_table_flusher
        }
        get_settings.each do |config|
          @threads << Thread.new {
            poll(config)
          }
        end
        $log.error "mysql_replicator_multi: stop working due to empty configuration" if @threads.empty?
      rescue StandardError => e
        $log.error "error: #{e.message}"
        $log.error e.backtrace.join("\n")
      end
    end

    def shutdown
      @threads.each do |thread|
        Thread.kill(thread)
      end
    end

    def get_settings
      manager_db = get_manager_connection
      settings = []
      query = "SELECT * FROM settings WHERE is_active = 1;"
      manager_db.query(query).each do |row|
        settings << row
      end
      return settings
    end

    def poll(config)
      begin
        masked_config = Hash[config.map {|k,v| (k == 'password') ? [k, v.to_s.gsub(/./, '*')] : [k,v]}]
        @mutex.synchronize {
          $log.info "mysql_replicator_multi: polling start. :config=>#{masked_config}"
        }
        primary_key = config['primary_key']
        previous_id = current_id = nil
        loop do
          start_time = Time.now
          db = get_origin_connection(config)
          db.query(config['query']).each do |row|
            @mutex.lock
            row.each {|k, v| row[k] = v.to_s if v.is_a?(Time) || v.is_a?(Date)}
            current_id = row[primary_key]
            if row[primary_key].nil?
              $log.error "mysql_replicator_multi: missing primary_key. :setting_name=>#{config['name']} :primary_key=>#{primary_key}"
              @mutex.unlock
              break
            end
            detect_insert_update(config, row)
            detect_delete(config, current_id, previous_id)
            previous_id = current_id
            @mutex.unlock
          end
          db.close
          elapsed_time = sprintf("%0.02f", Time.now - start_time)
          $log.info "mysql_replicator_multi: execution finished. :setting_name=>#{config['name']} :elapsed_time=>#{elapsed_time} sec"
          sleep config['interval']
        end
      rescue StandardError => e
        @mutex.synchronize {
          $log.error "mysql_replicator_multi: failed to execute query. :config=>#{masked_config}"
          $log.error "error: #{e.message}"
          $log.error e.backtrace.join("\n")
        }
      end
    end

    def detect_insert_update(config, row)
      primary_key = config['primary_key']
      current_id = row[primary_key]
      stored_hash = get_stored_hash(config['name'], current_id)
      current_hash = Digest::SHA1.hexdigest(row.flatten.join)

      event = nil
      if stored_hash.empty?
        event = :insert
      elsif stored_hash != current_hash
        event = :update
      end
      unless event.nil?
        tag = format_tag(@tag, {:name => config['name'], :event => event, :primary_key => config['primary_key']})
        emit_record(tag, row)
        update_hashtable({:event => event, :id => current_id, :setting_name => config['name'], :hash => current_hash})
      end
    end

    def get_stored_hash(setting_name, id)
      query = "SELECT SQL_NO_CACHE setting_query_hash FROM hash_tables WHERE setting_query_pk = #{id.to_i} AND setting_name = '#{setting_name}'"
      @manager_db.query(query).each do |row|
        return row['setting_query_hash']
      end
    end

    def detect_delete(config, current_id, previous_id)
      return if config['enable_delete'] != 1 || previous_id.nil?
      deleted_ids = collect_gap_ids(config['name'], current_id, previous_id)
      unless deleted_ids.empty?
        event = :delete
        deleted_ids.each do |id|
          tag = format_tag(@tag, {:name => config['name'], :event => event, :primary_key => config['primary_key']})
          emit_record(tag, {config['primary_key'] => id})
        end
        update_hashtable({:event =>  event, :ids => deleted_ids, :setting_name => config['name']})
      end
    end

    def collect_gap_ids(setting_name, current_id, previous_id)
      if (current_id - previous_id) > 1
        query = "SELECT SQL_NO_CACHE setting_query_pk FROM hash_tables
          WHERE setting_name = '#{setting_name}' 
          AND setting_query_pk > #{previous_id.to_i} AND setting_query_pk < #{current_id.to_i}"
      elsif previous_id > current_id
        query = "SELECT SQL_NO_CACHE setting_query_pk FROM hash_tables
          WHERE setting_name = '#{setting_name}' 
          AND setting_query_pk > #{previous_id.to_i}"
      elsif previous_id == current_id
        query = "SELECT SQL_NO_CACHE setting_query_pk FROM hash_tables
          WHERE setting_name = '#{setting_name}' 
          AND (setting_query_pk > #{current_id.to_i} OR setting_query_pk < #{current_id.to_i})"
      end
      ids = Array.new
      unless query.nil?
        @manager_db.query(query).each do |row|
          ids << row['setting_query_pk']
        end
      end
      return ids
    end

    def update_hashtable(opts)
      case opts[:event]
      when :insert
        add_hash_table_buffer(opts[:setting_name], opts[:id], opts[:hash])
      when :update
        query = "UPDATE hash_tables SET setting_query_hash = '#{opts[:hash]}' WHERE setting_name = '#{opts[:setting_name]}' AND setting_query_pk = '#{opts[:id]}'"
      when :delete
        query = "DELETE FROM hash_tables WHERE setting_name = '#{opts[:setting_name]}' AND setting_query_pk IN(#{opts[:ids].join(',')})"
      end
      @manager_db.query(query) unless query.nil?
    end

    def format_tag(tag, param)
      pattern = {'${name}' => param[:name], '${event}' => param[:event].to_s, '${primary_key}' => param[:primary_key]}
      tag.gsub(/\${[a-z_]+(\[[0-9]+\])?}/, pattern) do
        $log.warn "mysql_replicator_multi: missing placeholder. :tag=>#{tag} :placeholder=>#{$1}" unless pattern.include?($1)
        pattern[$1]
      end
    end

    def add_hash_table_buffer(setting_name, id, hash)
      @hash_table_bulk_insert << "('#{setting_name}','#{id}','#{hash}')"
      flush_hash_table if @hash_table_bulk_insert.size >= @bulk_insert_count
    end

    def hash_table_flusher
      begin
        loop do
          if @hash_table_bulk_insert.empty? || @bulk_insert_timeout > (Time.now - @hash_table_bulk_insert_last_time)
            sleep @bulk_insert_timeout
            next
          end
          @mutex.synchronize {
            flush_hash_table 
          }
        end
      rescue StandardError => e
        @mutex.synchronize {
          $log.error "mysql_replicator_multi: failed to flush buffered query. :config=>#{masked_config}"
          $log.error "error: #{e.message}"
          $log.error e.backtrace.join("\n")
        }
      end
    end

    def flush_hash_table
      return if @hash_table_bulk_insert.empty?
      query = "INSERT INTO hash_tables (setting_name,setting_query_pk,setting_query_hash) VALUES #{@hash_table_bulk_insert.join(',')}"
      @manager_db.query(query)
      @hash_table_bulk_insert.clear
      @hash_table_bulk_insert_last_time = Time.now
    end

    def emit_record(tag, record)
      Engine.emit(tag, Engine.now, record)
    end

    def get_manager_connection
      begin
        return Mysql2::Client.new(
          :host => @manager_host,
          :port => @manager_port,
          :username => @manager_username,
          :password => @manager_password,
          :database => @manager_database,
          :encoding => 'utf8',
          :reconnect => true,
          :stream => false,
          :cache_rows => false
        )
      rescue Exception => e
        $log.warn "mysql_replicator_multi: #{e}"
        sleep @reconnect_interval
        retry
      end
    end

    def get_origin_connection(config)
      begin
        return Mysql2::Client.new(
          :host => config['host'],
          :port => config['manager_port'],
          :username => config['username'],
          :password => config['password'],
          :database => config['database'],
          :encoding => 'utf8',
          :reconnect => true,
          :stream => true,
          :cache_rows => false
        )
      rescue Exception => e
        $log.warn "mysql_replicator_multi: #{e}"
        sleep @reconnect_interval
        retry
      end
    end
  end
end
