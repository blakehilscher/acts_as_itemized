module ActsAsItemized
  
  def self.included(base)
    base.extend ClassMethods
  end

  module ClassMethods
    def acts_as_itemized
      send :include, InstanceMethods
      send :extend, SingletonMethods
    
      after_save :commit_item_changes
      
      has_many :itemized_items, :order => "position" do
        def where_type(conditions)
          conditions = (conditions.is_a? Array) ? conditions.collect(&:to_s) : conditions.to_s
          scoped(:conditions => {:item_type => conditions } )
        end
        def where_position(conditions)
          conditions.collect!(&:to_i) if conditions.is_a? Array
          scoped(:conditions => {:position => conditions})
        end
        def scores
          all.collect(&:score)
        end
        def contents
          all.collect(&:content)
        end
        def notes
          all.collect(&:note)
        end
        def to_h
          all.inject({}) do |result, item|
            key = item.item_type
            result[key] = ( result[key] || {} ).merge(item.to_h)
            result
          end
        end
      
      end
    
    end
  
  end

  module SingletonMethods
    def items(type = false)
      sql = (sql || "") + "itemized_items.item_type = ? AND " if type
      sql = (sql || "") + "itemized_items.parent_id IN (?) "
      conditions = [sql] 
      conditions << type.to_s if type
      conditions << all
      ItemizedItem.scoped(:conditions => conditions)
    end
  end

  module InstanceMethods
  
    def items
      itemized_items
    end
    
    def item_options
      @item_options ||= {}
    end
    def item_options_with_sorting
      item_options.sort_by{|k,io| io[:position] || 0}
    end

    # Load items into @attributes from self.itemized_items
    def eager_load_items
      item_options.each do |type_many, options|
        type_one = type_many.to_s.singularize
        item_options[type_many][:count].times do |id|
          position = id + 1
          options[:columns].each do |column|
            self.send("#{type_one}_#{column}_#{position}")
          end
        end
      end
      self.attributes
    end

    # ITEM CHANGES

    def item_changes
      @item_changes ||= {}
    end
    def previous_item_changes
      @previous_item_changes ||= {}
    end
    def items_changed?
      !item_changes.blank?
    end
    def previous_items_changed?
      !previous_item_changes.blank?
    end

    def reload
      item_changes.each{|key,values| @attributes.delete(key) }
      super
    end


    protected
  
    # ITEM CHANGES
    def add_items(*args)
      args.each do |arg|
        next if item_options.has_key?(arg.is_a?(Hash) ? arg.keys.first : arg)
        options = item_options_with_defaults(arg)
        @item_options.merge!(options)
        create_item_accessors(options)
      end
    end
    
    def item_options_with_defaults(arg)
      key = arg.is_a?(Hash) ? arg.keys.first : arg.to_sym
      options = arg.is_a?(Hash) ? arg[key] : {}
      options = {
        :count      =>  1,
        :columns    =>  [:content],
        :position   =>  item_position_with_auto_increment,
        :name       =>  key.to_s.titleize,
        :tabindex   =>  [],
      }.merge(options)
      options[:tabindex] = tabindex_with_auto_increment(options[:count], options[:tabindex][0], options[:tabindex][1], options[:tabindex][2])
      options[:tabindex_score] = tabindex_with_auto_increment(options[:count], options[:tabindex_score][0], options[:tabindex_score][1], options[:tabindex_score][2]) if options[:tabindex_score]
      return {key => options}
    end
  
    def set_item_change(changes)
      changes.each do |key, value|
        next if attributes[key] == value
        @item_changes[key] = [attributes[key]] unless item_changes.has_key?(key)
        @item_changes[key][1] = value
      end
    end
    def commit_item_changes
      item_changes.each do |key, values|
        update_or_create_item(key, values[1])
      end
      rotate_item_changes
    end
    def rotate_item_changes
      @previous_item_changes = item_changes
      @item_changes = {}
    end
  

    private
  
    def item_position
      @item_position ||= 0
    end
    def item_position_with_auto_increment
      @item_position = item_position + 1
    end
  
    def tabindex
      @tabindex ||= 1
    end
    def tabindex_with_auto_increment(*args)
      # args
      times = (args.first || 1)
      increase_by = (args.second || 1)
      offset = (args.third || 1) - 1
      alternation = (args.fourth || false)
      alternate = false
      # tabindex
      ticker = tabindex
      total = (tabindex) + (times * increase_by)
      @tabindex = tabindex + times
      # iterate
      result = []
      if alternation
        while ticker < total do
          result << (ticker + offset) + (alternate ? (times / 2) : (((total - ticker) / 2) - (times / 2)) )
          alternate = !alternate
          ticker += increase_by
        end
      else
        while ticker < total do
          result << (ticker + offset) - (times * offset)
          ticker += increase_by
        end
      end
      result
    end

  
    # ITEM CRUD
  
    def create_item_accessors(_item_options)
      _item_options.each do |type_many, options|
        # singular item
        type_one = type_many.to_s.singularize
        # total
        count = _item_options[type_many][:count]
        # access all of type
        class_eval <<-END, __FILE__, (__LINE__+1)
          def #{type_many}
            @#{type_many} ||= #{count}.times.inject([]){|r,position| r << self.items.detect{|i| i.item_type == '#{type_many}' && i.position == position }; r}
          end
        END
        # for each item type this many times
        count.times do |id|
          position = id + 1
          # individual accessors
          options[:columns].each do |column|
            # create getter, setter, and config
            next if self.respond_to? "#{type_one}_#{column}_#{position}"
            class_eval <<-END, __FILE__, (__LINE__+1)
              def #{type_one}_#{column}_#{position}
                get_item_value("#{type_one}_#{column}_#{position}")
              end
              def #{type_one}_#{column}_#{position}=(value)
                set_item_value("#{type_one}_#{column}_#{position}", value)
              end
              def #{type_one}_#{column}_#{position}_options
                @#{type_one}_#{column}_#{position}_options ||= item_options[:#{type_many}].merge({ :item_type => '#{type_many}', :column => '#{column}', :position => #{position} })
              end
            END
          end
        end
      end
    
    end
  
  
    # ITEM GETTER & SETTER

    def get_item_value(key)
      @attributes[key] = get_item_record(key) unless @attributes.has_key?(key)
      @attributes[key]
    end

    def set_item_value(key, value)
      options = self.send("#{key}_options")
      if options[:through] && self.respond_to?(options[:through]) && !self.send(options[:through]).blank?
        self.send(options[:through]).send("#{key}=", value) 
      else
        set_item_change({ key => value })
      end
      @attributes[key] = value
    end
  
  
    def get_item_record(key)
      options = self.send("#{key}_options")
      # get through delegate, if defined
      return self.send(options[:through]).send(key) if options[:through] && self.respond_to?(options[:through]) && !self.send(options[:through]).blank?
      # get through itemized_item record
      return nil unless item = items.detect{|i| i.item_type == options[:item_type] && i.position == options[:position] }
      item.send options[:column]
    end

    def update_or_create_item(key, value)
      options = self.send("#{key}_options")
      # find or create
      item = items.detect{|i| i.item_type == options[:item_type] && i.position == options[:position]} || create_item(options[:item_type], options[:position])
      # update
      item.send("#{options[:column]}=", value)
      item.save
    end
  
    def create_item(item_type, position, conditions = {})
      record = conditions.merge({:item_type => item_type.to_s, :position => position})
      items.create(record)
    end


  end

end

ActiveRecord::Base.class_eval { include ActsAsItemized }