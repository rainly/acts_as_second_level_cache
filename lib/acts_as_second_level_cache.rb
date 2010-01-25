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
    
    # 用缓存的方式查询，请手动清除
    def get_cache(id)
      if !id.blank? and (id != 0)
        Rails.cache.fetch("models/#{self.class_name.tableize}/#{id}") {
          begin  
            find(id)
          rescue
            nil
          end          
        }
      else
        nil
      end
    end
    
    # 缓存处理，根据字段名取数据
    #   如：
    #     Place.get_cache_by_name("slug","cheng-du")
    #     User.get_cache_by_name("login","huacnlee")
    def get_cache_by_name(field,value)
      cache_key = "models/#{self.class_name.tableize}/#{field}/#{value}"
      
      if not id = Rails.cache.read(cache_key)
        item = find(:first,:conditions => ["#{field} = ?",value])
        if !item.blank?
          id = item.id
          Rails.cache.write(cache_key,id,:tags => "#{self.class_name.tableize.singularize}_#{id}")
        end
      else
        item = get_cache(id)
      end
      item
    end
    
    # 缓存单条记录的查询
    def cache_item(key)
      cache_key = "models/#{self.class_name.tableize}/#{key}/id"
      id = Rails.cache.read(cache_key)
      if id == nil
        item = yield
        Rails.cache.write(cache_key,item,:tags => "#{self.class_name.tableize.singularize}")
        item
      else
        get_cache(id)
      end
    end
    
    # 缓存查询集合，适用于返回list的查询，并分隔为单条存入 Memcached
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
    
    # 缓存will_paginate 的查询结果
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
        Rails.cache.write(paginate_info_cache_key,paginate_info,:tags => "#{self.class_name.tableize.singularize}")
        # 返回真实数据
        items
      else
        # 根据缓存的 ids 去除数据集合
        items = get_caches_by_ids(paginate_info[:ids])
        # 生成 WillPaginate 集合，并将paginate_info的值放入
        paginate_items = WillPaginate::Collection.new(paginate_info[:current_page],paginate_info[:per_page],paginate_info[:total_entries])
        # 循环 items 将数据放入 WillPaginate 集合
        items.each { |item| paginate_items << item }
        paginate_items
      end
    end
    
    
    private
    def read_cached_ids(key)
      Rails.cache.read("#{key}/ids") || nil
    end
    
    def write_cached_ids(key,items)
      if items.class == [].class
        ids = items.collect { |item| item.id  }
      else
        ids = [items.id]
      end
      Rails.cache.write("#{key}/ids",ids,:tags => "#{self.class_name.tableize.singularize}")
      ids
    end
      
    public
    # 根据ids列表查询集合
    # === 参数说明
    #     ids     可以为 array 或 字符串，如 [1,2,3,4] 或 "1,2,3,4"
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
  end
end

ActiveRecord::Base.send(:include, ActsAsSecondLevelCache)