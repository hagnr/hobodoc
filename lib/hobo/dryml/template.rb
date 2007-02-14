require 'rexml/document'

module Hobo::Dryml

  APPLICATION_TAGLIB = "hobolib/application"
  CORE_TAGLIB = "plugins/hobo/tags/core"

  class Template
    DRYML_NAME = "[a-zA-Z_][a-zA-Z0-9_]*"

    def initialize(src, environment, template_path)
      @src = src
      @environment = environment # a class or a module

      @template_path = template_path.sub(/^#{Regexp.escape(RAILS_ROOT)}/, "")

      @last_element = nil
    end

    attr_reader :tags, :template_path

    def compile(local_names=[], auto_taglibs=true)
      now = Time.now
      if auto_taglibs
        import_taglib(CORE_TAGLIB)
        import_taglib(APPLICATION_TAGLIB)
        Hobo::MappingTags.apply_standard_mappings(@environment)
      end

      if is_taglib?
        process_src
      else
        create_render_page_method(local_names)
      end
      logger.info("DRYML: Compiled #{template_path} in %.2fs" % (Time.now - now))
    end
      
      
    def create_render_page_method(local_names)
      erb_src = process_src
      src = ERB.new(erb_src).src[("_erbout = '';").length..-1]

      locals = local_names.map{|l| "#{l} = __local_assigns__[:#{l}];"}.join(' ')

      method_src = ("def render_page(__page_this__, __local_assigns__); " +
                    "#{locals} new_object_context(__page_this__) do " +
                    src +
                    "; end + part_contexts_js; end")

      @environment.class_eval(method_src, template_path, 1)
      @environment.compiled_local_names = local_names
    end

    
    def is_taglib?
      @environment.class == Module
    end

    
    def process_src
      # Replace <%...%> scriptlets with xml-safe references into a hash of scriptlets
      @scriptlets = {}
      src = @src.gsub(/<%(.*?)%>/m) do
        _, scriptlet = *Regexp.last_match
        id = @scriptlets.size + 1
        @scriptlets[id] = scriptlet
        newlines = "\n" * scriptlet.count("\n")
        "[![HOBO-ERB#{id}#{newlines}]!]"
      end

      @xmlsrc = "<dryml_page>" + src + "</dryml_page>"

      @doc = REXML::Document.new(RexSource.new(@xmlsrc))

      erb_src = restore_erb_scriptlets(children_to_erb(@doc.root))

      erb_src
    end


    def restore_erb_scriptlets(src)
      src.gsub(/\[!\[HOBO-ERB(\d+)\s*\]!\]/m) { "<%#{@scriptlets[Regexp.last_match[1].to_i]}%>" }
    end


    def erb_process(src)
      ERB.new(restore_erb_scriptlets(src)).src
    end


    def children_to_erb(nodes)
      nodes.map{|x| node_to_erb(x)}.join
    end


    def node_to_erb(node)
      case node

      # v important this comes before REXML::Text, as REXML::CData < REXML::Text
      when REXML::CData
        REXML::CData::START + node.to_s + REXML::CData::STOP

      when REXML::Text
        node.to_s

      when REXML::Element
        element_to_erb(node)
      end
    end


    def element_to_erb(el)
      dryml_exception("badly placed parameter tag <#{el.name}>", el) if
        el.name.starts_with?(":")

      @last_element = el
      case el.name

      when "taglib"
        taglib_element(el)
        # return nothing - the import has no presence in the erb source
        ""
        
      when "set_theme"
        require_attribute(el, "name", /^#{DRYML_NAME}$/)
        set_theme(el.attributes['name'])
        # return nothing - set_theme has no presence in the erb source
        ""

      when "def"
        def_element(el)

      when "tagbody"
        tagbody_element(el)

      else
        if el.name.not_in?(Hobo.static_tags) or
            el.attributes['replace_option'] or el.attributes['content_option']
          tag_call(el)
        else
          html_element_to_erb(el)
        end
      end
    end


    def taglib_element(el)
      require_toplevel(el)
      require_attribute(el, "as", /^#{DRYML_NAME}$/, true)
      if el.attributes["src"]
        import_taglib(el.attributes["src"], el.attributes["as"])
      elsif el.attributes["module"]
        import_module(el.attributes["module"].constantize, el.attributes["as"])
      end
    end
    
    
    def expand_template_path(path)
      base = if path.starts_with? "plugins"
               "vendor/" + path
             elsif path.include?("/")
               "app/views/#{path}"
             else
               template_dir = File.dirname(template_path)
               "#{template_dir}/#{path}"
             end
       base + ".dryml"
    end


    def import_taglib(src_path, as=nil)
      path = expand_template_path(src_path)
      unless template_path == path
        taglib = Taglib.get(RAILS_ROOT + (path.starts_with?("/") ? path : "/" + path))
        taglib.import_into(@environment, as)
      end
    end


    def import_module(mod, as=nil)
      raise NotImplementedError.new if as
      @environment.send(:include, mod)
    end
    
    
    def set_theme(name)
      if Hobo.current_theme.nil? or Hobo.current_theme == name
        Hobo.current_theme = name
        import_taglib("hobolib/themes/#{name}/application")
        mapping_module = "#{name}_mapping"
        if File.exists?(path = RAILS_ROOT + "/app/views/hobolib/themes/#{mapping_module}.rb")
          load(path)
          Hobo::MappingTags.apply_mappings(@environment)
        end
      end
    end
      

    def def_element(el)
      require_toplevel(el)
      require_attribute(el, "tag", /^#{DRYML_NAME}$/)
      require_attribute(el, "attrs", /^\s*#{DRYML_NAME}(\s*,\s*#{DRYML_NAME})*\s*$/, true)
      require_attribute(el, "alias_of", /^#{DRYML_NAME}$/, true)
      require_attribute(el, "alias_current", /^#{DRYML_NAME}$/, true)

      name = el.attributes["tag"]

      alias_of = el.attributes['alias_of']
      alias_current = el.attributes['alias_current']

      dryml_exception("def cannot have both alias_of and alias_current", el) if alias_of && alias_current
      dryml_exception("def with alias_of must be empty", el) if alias_of and el.size > 0

      if alias_of || alias_current
        old_name = alias_current ? name : alias_of
        new_name = alias_current ? alias_current : name

        begin
          @environment.send(:alias_method, new_name.to_sym, old_name.to_sym)
        rescue
          dryml_exception("cannot alias '#{old_name}' as '#{new name}", el)
        end
      end

      if alias_of
        "<% #{tag_newlines(el)} %>"
      else
        attrspec = el.attributes["attrs"]
        attr_names = attrspec ? attrspec.split(/\s*,\s*/) : []

        invalids = attr_names & %w{obj attr this}
        dryml_exception("invalid attrs in def: #{invalids * ', '}", el) unless invalids.empty?

        create_tag_method(el, name.to_sym, attr_names.omap{to_sym})
      end
    end


    def create_tag_method(el, name, attrs)
      name = Hobo::Dryml.unreserve(name)

      # A statement to assign values to local variables named after the tag's attrs.
      # Careful to unpack the list returned by _tag_locals even if there's only
      # a single var (options) on the lhs (hence the trailing ',' on options)
      setup_locals = ( (attrs.map{|a| "#{Hobo::Dryml.unreserve(a)}, "} + ['options,']).join +
                       " = _tag_locals(__options__, #{attrs.inspect})" )

      start = "_tag_context(__options__, __block__) do |tagbody| #{setup_locals}"

      method_src = ( "<% def #{name}(__options__={}, &__block__); #{start} " +
                     # reproduce any line breaks in the start-tag so that line numbers are preserved
                     tag_newlines(el) + "%>" +
                     children_to_erb(el) +
                     "<% @output; end; end %>" )
      
      src = erb_process(method_src)
      @environment.class_eval(src, template_path, element_line_num(el))

      # keep line numbers matching up
      "<% #{"\n" * method_src.count("\n")} %>"
    end


    def tagbody_element(el)
      dryml_exception("tagbody can only appear inside a <def>", el) unless
        find_ancestor(el) {|e| e.name == 'def'}
      dryml_exception("tagbody cannot appear inside a part", el) if
        find_ancestor(el) {|e| e.attributes['part_id']}
      tagbody_call(el)
    end


    def tagbody_call(el)
      options = if obj = el.attributes['obj']
                  "{ :obj => #{attribute_to_ruby(obj)} }"
                elsif attr = el.attributes['attr']
                  "{ :attr => #{attribute_to_ruby(attr)} }"
                else
                  ""
                end
      else_ = attribute_to_ruby(options['else'])
      "<%= tagbody ? tagbody.call(#{options}) : #{else_} %>"
    end


    def part_element(el, content)
      require_attribute(el, "part_id", /^#{DRYML_NAME}$/)
      part_name  = el.attributes['part_id']
      dom_id = el.attributes['id'] || part_name

      part_src = "<% def #{part_name}_part #{tag_newlines(el)}; new_context do %>" +
        content +
        "<% end; end %>"
      create_part(part_src, element_line_num(el))

      newlines = "\n" * part_src.count("\n")
      res = "<%= call_part(#{attribute_to_ruby(dom_id)}, :#{part_name}) #{newlines} %>"
      res
    end


    def create_part(erb_src, line_num)
      src = erb_process(erb_src)
      # Add a method to the part module for this template
      @environment.class_eval(src, template_path, line_num)
    end

    
    def tag_call(el)
      require_attribute(el, "inner", /#{DRYML_NAME}/, true)
      
      # find out if it's empty before removing any <:param_tags>
      empty_el = el.size == 0

      # gather <:param_tags>, and remove them from the dom
      param_tags = get_parameter_tags(el)
        
      name = Hobo::Dryml.unreserve(el.name)
      options = tag_options(el, param_tags)
      newlines = tag_newlines(el)
      replace_option = el.attributes["replace_option"]
      content_option = el.attributes["content_option"]
      dryml_exception("both replace_option and content_option given") if replace_option && content_option
      call = if replace_option
               "call_replaceable_tag(:#{name}, #{options}, options[:#{replace_option}])"
             elsif content_option
               "call_replaceable_content_tag(:#{name}, #{options}, options[:#{content_option}])"
             else
               "#{name}(#{options})"
             end

      part_id = el.attributes['part_id']
      if empty_el
        if part_id
          "<span id='#{part_id}'>" + part_element(el, "<%= #{call} %>") + "</span>"
        else
          "<%= #{call} #{newlines}%>"
        end
      else
        children = children_to_erb(el)
        if part_id
          id = el.attributes['id'] || part_id
          "<span id='<%= #{attribute_to_ruby(id)} %>'>" +
            part_element(el, "<% _erbout.concat(#{call} do %>#{children}<% end) %>") +
            "</span>"
        else
          "<% _erbout.concat(#{call} do #{newlines}%>#{children}<% end) %>"
        end
      end
    end
    
    
    def get_parameter_tags(el)
      param_tags = {}
      el.elements.each do |e|
        if e.name.starts_with?(":")
          e.remove
          
          param_value = if e.has_attributes?
                          # A param tag with attributes becomes a hash, e.g. <:foo x="y"/>  =>  { :x => 'y' }
                          hash = Hash.build(e.attributes.keys) {|n| [n, attribute_to_ruby(e.attributes[n])]}
                          # If there is content to, that goes in the has under the key :content
                          if e.size > 0
                            hash[:content] = "(capture do %>#{children_to_erb(e)}<%; end)"
                          end
                          hash_to_ruby(hash)
                        elsif e.size > 0
                          "(capture do %>#{children_to_erb(e)}<%; end)"
                        else
                          dryml_exception("valueless parameter tag")
                        end
          
          param_name = e.name[1..-1]
          current = param_tags[param_name]
          param_tags[param_name] = if current.nil?
                                     param_value
                                   elsif current.is_a? Array
                                     current + [param_value]
                                   else
                                     [current, param_value]
                                   end
        end
      end
      param_tags.each {|k, v| param_tags[k] = "[#{v * ', '}]" if v.is_a?(Array) }
      param_tags
    end


    def tag_options(el, param_tags)
      attributes = el.attributes

      # ensure no param given as both attribute and <:tag>
      dryml_exception("duplicate attribute/parameter-tag #{param}", el) unless
        (param_tags.keys & attributes.keys).empty?
      
      options = hash_to_ruby(all_options(attributes, param_tags))

      xattrs = el.attributes['xattrs']
      if xattrs
        extra_options = if xattrs.blank?
                          "options"
                        elsif xattrs.starts_with?("#")
                          xattrs[1..-1]
                        else
                          dryml_exception("invalid xattrs", el)
                        end
        "#{options}.update(#{extra_options})"
      else
        options
      end
    end


    def all_options(attributes, param_tags)
      opts = {}
      (attributes.keys + param_tags.keys).each do |name|
        value = if param_tags.include?(name)
                  param_tags[name]
                else
                  attribute_to_ruby(attributes[name])
                end
        begin
          add_option(opts, name.split('.'), value)
        rescue DrymlExcpetion
          dryml_exception("inner-attribute conflict for {name}")
        end
      end
      opts
    end
    
    def hash_to_ruby(hash)
      pairs = hash.map do |k, v|
        val = v.is_a?(Hash) ? hash_to_ruby(v) : v
        ":#{k} => #{val}"
      end
      "{ #{pairs * ', '} }"
    end
    
    def add_option(options, names, value)
      if names.length == 1
        options[names.first] = value
      elsif names.length > 1
        v = options[names.first]
        if v.is_a? Hash
          # it's ready for the inner-attribute - do nothing
        elsif v.nil?
          options[names.first] = v = {}
        else
          # Conflict, i.e. a = "ping" and a.b = "pong"
          # Rescued by caller (all_options)
          raise DrymlExcpetion.new
        end
        add_option(v, names[1..-1], value)
      end
    end

    
    def html_element_to_erb(el)
      start_tag_src = el.instance_variable_get("@start_tag_source").
        gsub(REXML::CData::START, "").gsub(REXML::CData::STOP, "")

      xattrs = el.attributes["xattrs"]
      if xattrs
        attr_args = if xattrs.starts_with?('#')
                      xattrs[1..-1]
                    elsif xattrs.blank?
                      "options"
                    else
                      dryml_exception("invalid xattrs", el)
                    end
        class_attr = el.attributes["class"]
        if class_attr
          raise HoboError.new("invalid class attribute with xattrs: '#{class_attr}'") if
            class_attr =~ /'|\[!\[HOBO-ERB/

          attr_args.concat(", '#{class_attr}'")
          start_tag_src.sub!(/\s*class\s*=\s*('[^']*?'|"[^"]*?")/, "")
        end
        start_tag_src.sub!(/\s*xattrs\s*=\s*('[^']*?'|"[^"]*?")/, " <%= xattrs(#{attr_args}) %>")
      end

      if start_tag_src.ends_with?("/>")
        start_tag_src
      else
        if el.attributes['part_id']
          body = part_element(el, children_to_erb(el))
          if el.attributes["id"]
            # remove part_id, and eval the id attribute with an erb scriptlet
            start_tag_src.sub!(/\s*part_id\s*=\s*('[^']*?'|"[^"]*?")/, "")
            id_expr = attribute_to_ruby(el.attributes['id'])
            start_tag_src.sub!(/id\s*=\s*('[^']*?'|"[^"]*?")/, "id='<%= #{id_expr} %>'")
          else
            # rename part_id to id
            start_tag_src.sub!(/part_id\s*=\s*('[^']*?'|"[^"]*?")/, "id=\\1")
          end
          dryml_exception("multiple part ids", el) if start_tag_src.index("part_id=")


          start_tag_src + body + "</#{el.name}>"
        else
          start_tag_src + children_to_erb(el) + "</#{el.name}>"
        end
      end
    end

    def attribute_to_ruby(attr)
      dryml_exception("erb scriptlet in attribute of defined tag") if attr && attr.index("[![HOBO-ERB")
      if attr.nil?
        "nil"
      elsif is_code_attribute?(attr)
        "(#{attr[1..-1]})"
      else
        if not attr =~ /"/
          '"' + attr + '"'
        elsif not attr =~ /'/
          "'#{attr}'"
        else
          dryml_exception("invalid quote(s) in attribute value")
        end
      end
    end

    def find_ancestor(el)
      e = el.parent
      until e.is_a? REXML::Document
        return e if yield(e)
        e = e.parent
      end
      return nil
    end

    def require_toplevel(el)
      dryml_exception("<#{el.name}> can only be at the top level", el) if el.parent != @doc.root
    end

    def require_attribute(el, name, rx=nil, optional=false)
      val = el.attributes[name]
      if val
        dryml_exception("invalid #{name}=\"#{val}\" attribute on <#{el.name}>", el) unless val =~ rx
      else
        dryml_exception("missing #{name} attribute on <#{el.name}>", el) unless optional
      end
    end

    def dryml_exception(message, el=nil)
      el ||= @last_element
      raise DrymlException.new(message + " -- at #{template_path}:#{element_line_num(el)}")
    end

    def element_line_num(el)
      offset = el.instance_variable_get("@source_offset")
      line_no = @xmlsrc[0..offset].count("\n") + 1
    end

    def tag_newlines(el)
      src = el.instance_variable_get("@start_tag_source")
      "\n" * src.count("\n")
    end

    def is_code_attribute?(attr_value)
      attr_value.starts_with?("#")
    end

    def logger
      ActionController::Base.logger rescue nil
    end

  end

end
