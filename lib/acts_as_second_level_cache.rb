# = acts_as_second_level_cache
# version: 0.2
# Simple to cache your data with Memcached
# 
module ActsAsSecondLevelCache
  
  def self.included(base)
    base.extend ClassMethods  
  end
  
  module ClassMethods
    def acts_as_second_level_cache
      include ActsAsSecondLevelCache::InstanceMethods
      class_eval do
        # ===============================
        # 集合/单数据缓存
        # ===============================
        after_update :clear_get_cache
        after_create :clear_list_cache
        after_destroy :clear_list_cache
      end
    end
    
    # == 用缓存的方式查询单条记录，代替 find_by_id
    # Example:
    #   Place.get_cache(params[:id])
    # 
    # 请不要使用 include，不起任何作用
    def get_cache(id)
      if !id.blank? and (id != 0)
        item = Rails.cache.fetch("models/#{self.class_name.tableize}/#{id}") {
          begin  
            find(id)
          rescue
            nil
          end          
        }
        
        if item
          item.dup
        else
          nil
        end          
      else
        nil
      end
    end    
    
    
    # == 缓存处理，根据字段名取数据
    # Example:
    #     Place.get_cache_by_name("slug","cheng-du")
    #     User.get_cache_by_name("login","huacnlee")
    def get_cache_by_name(field,value)
      cache_key = "models/#{self.class_name.tableize}/#{field}/#{value}"
      
      if not id = Rails.cache.read(cache_key)
        item = find(:first,:conditions => ["#{field} = ?",value])
        if !item.blank?
          id = item.id
          Rails.cache.write(cache_key,id,:tags => ["#{self.class_name.tableize.singularize}_#{id}"])
        end
      else
        item = get_cache(id)
      end
      item
    end
    
    # == 缓存单条记录的查询
    # Example:
    #   def self.find_last
    #     cache_item("find_last") do
    #       last
    #     end
    #   end
    def cache_item(key)
      cache_key = "models/#{self.class_name.tableize}/#{key}/id"
      id = Rails.cache.read(cache_key)
      if id == nil
        item = yield
        Rails.cache.write(cache_key,item,:tags => ["#{self.class_name.tableize.singularize}"])
        item
      else
        get_cache(id)
      end
    end
    
    # == 缓存查询集合，适用于返回list的查询，并分隔为单条存入 Memcached
    # Example:
    #   def self.find_recents(limit = 20)
    #     cache_items("find_recents/#{limit}") do
    #       find(:all,:limit => limit, :order => "id desc")
    #     end
    #   end
    def cache_items(key)
      cache_key = "models/#{self.class_name.tableize}/#{key}"
      ids = read_cached_ids(cache_key)
      if ids == nil
        items = yield
        ids = write_cached_ids(cache_key,items)
        items
      else
        get_caches_by_ids(ids)
      end
    end
    
    # == 缓存will_paginate 的查询结果
    # Example:
    #   def self.find_list(page = 1, per_page = 20)
    #     cache_items_with_paginate("find_list/#{page}_#{per_page}") do
    #       paginate(:page => page,:per_page => per_page, :order => "id desc")
    #     end
    #   end
    def cache_items_with_paginate(key)
      cache_key = "models/#{self.class_name.tableize}/#{key}"
      paginate_info_cache_key = "#{cache_key}/paginate_info"
      paginate_info = Rails.cache.read(paginate_info_cache_key)
      if not paginate_info
        # 真实运算
        items = yield
        # 创建一个没数据的 WillPaginate 集合，以便可以将分页信息存入缓存
        paginate_info = {:ids => items.collect { |item| item.id  }, 
                         :current_page => items.current_page,
                         :per_page => items.per_page,
                         :total_entries => items.total_entries}
        Rails.cache.write(paginate_info_cache_key,paginate_info,:tags => ["#{self.class_name.tableize.singularize}"])
        # 存下 items 到 cache
        set_cache_items(items)
        # 返回真实数据
        items
      else
        # 根据缓存的 ids 去除数据集合
        items = get_caches_by_ids(paginate_info[:ids])
        # 生成 WillPaginate 集合，并将paginate_info的值放入
        paginate_items = WillPaginate::Collection.new(paginate_info[:current_page],paginate_info[:per_page],paginate_info[:total_entries])
        # 循环 items 将数据放入 WillPaginate 集合
        items.each do |item|
          paginate_items << item
        end
        paginate_items
      end
    end
    
    # == 根据ids列表查询集合
    # 参数说明:
    #     ids     可以为 array 或 字符串，如 [1,2,3,4] 或 "1,2,3,4"
    #
    # Example:
    #   Post.get_caches_by_ids([2,54,4])
    #
    def get_caches_by_ids(ids)
      id_array = []
      if ids.class == [].class
        id_array = ids
      else
        id_array = ids.split(",")
      end
      items = []
      id_array.each do |id|
        item = get_cache(id)
        items << item if not item == nil
      end
      
      items
    end    
    
    private
    def read_cached_ids(key)
      Rails.cache.read("#{key}/ids") || nil
    end
    
    def write_cached_ids(key,items)
      if items.class == [].class
        ids = []
        items.each do |item|
          ids << item.id          
        end
        # 存下 items 到 cache
        set_cache_items(items)
      else
        ids = [items.id]
        # 存下item
        set_cache_item(items)
      end
      Rails.cache.write("#{key}/ids",ids,:tags => ["#{self.class_name.tableize.singularize}"])
      ids
    end
      
    # 存单条记录的缓存    
    def set_cache_item(item)
      if not item
        return
      end
      cache_item = Rails.cache.read("models/#{self.class_name.tableize}/#{item.id}")
      if not cache_item
        Rails.cache.write("models/#{self.class_name.tableize}/#{item.id}",item)
      end
    end
    
    # 开线程将得到的 items 集合写入缓存
    def set_cache_items(items)
      th = Thread.new do
        if not items.blank?
          items.each do |item|
            set_cache_item(item)
          end
        end
      end
    end
    
  end
  
  module InstanceMethods
    private
    def clear_get_cache
      # 数据更改的时候清除缓存
      Rails.cache.delete("models/#{self.class.to_s.tableize}/#{self.id}")
      Rails.cache.delete_by_tag("#{self.class.to_s.tableize.singularize}_#{self.id}")
    end
    
    def clear_list_cache
      # 清除集合性的缓存
      Rails.cache.delete_by_tag("#{self.class.to_s.tableize.singularize}")
    end
    
    public
    # == 将 frozen 的 hash unfreeze
    # 临时解决 Rails.cache.fetch 后 can't modify frozen hash 的错误
    def dup
      obj = super
      obj.instance_variable_set('@attributes', instance_variable_get('@attributes').dup)
      obj
    end
  end
end

ActiveRecord::Base.send(:include, ActsAsSecondLevelCache)