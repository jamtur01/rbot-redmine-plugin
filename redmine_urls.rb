# redmine_urls crudely updated by James Turnbull 
# based on trac_urls written by wombie
# Needs to go in the plugins dir for rbot

require 'net/https'
require 'uri'
require 'rubygems'
require 'hpricot'

class InvalidRedmineUrl < Exception
end

class RedmineUrlsPlugin < Plugin
	Config.register Config::ArrayValue.new('redmine_urls.channelmap',
		:default => [], :requires_restart => false,
		:desc => "A map of channels to the base Redmine URL that should be used " +
		         "in that channel.  Format for each entry in the list is " +
		         "#channel:http://redmine.site/to/use.  Don't put a trailing " +
		         "slash on the base URL, please.")

	Config.register Config::BooleanValue.new('redmine_urls.https', 
		:default => [], :requires_restart => false,
		:desc => "Use https to get Redmine urls and tickets, valid values are true and false, defaults to false")

	Config.register Config::BooleanValue.new('redmine_urls.basic_auth',
		:default => [], :requires_restart => false,
		:desc =>	"Use basic http authentification for Redmine urls." +
							"Needs redmine_urls.basic_auth_username and redmine_urls.basic_auth_password as well to do anything")

	Config.register Config::StringValue.new('redmine_urls.basic_auth_username',
		:default => [], :requires_restart => false,
		:desc => "Username for basic http authentification to the Redmine site")


	Config.register Config::StringValue.new('redmine_urls.basic_auth_password',
		:default => [], :requires_restart => false,
		:desc => "Password for basic http authentification to the Redmine site")

	def help(plugin, topic = "")
		case topic
			when '':
				"Redmine_urls: Convert common Redmine WikiSyntax references into URLs. " +
				"I will watch the channel for likely references (see subtopic " +
				"'general'), and also respond to specific requests (see " +
				"subtopic 'queries')."
			
			when 'general':
				"I can convert common references into URLs when I " +
				"see them mentioned in conversation.  Currently supports " +
				"[NNN], rNNN => revision URL; changeset:NNN|SHA => revision URL;" + 
                                "#NN => bug URL; wiki:CamelCase => wiki URL." +
                                "URLs are verified before they're sent to the channel, to limit noise." +
                                "I will not respond to general references if you are talking to me directly!" +
                                "See subtopic 'queries' for help with direct querying."
			
			when 'queries':
				"You can ask me to lookup some info about a Redmine bug, " +
				"changeset, or wiki page.  I'll give you the URL and the title " +
				"of the bug or page, " +
				"or the commit message of a changeset.  You must address me " +
				"directly to get a response.  Example: '#{@bot.nick}: redmineinfo " +
				"#93' will produce a URL and the ticket's title."
		end
	end
	
	def listen(m)
		# We're a conversation watcher, dammit, don't talk to me!
		return if m.address?
		
		# We don't handle private messages just yet, and we only handle regular
		# chat messages
		return unless m.kind_of?(PrivMessage) && m.public?
		
		refs = m.message.scan(/(?:^|\W)(\[\d+\]|r\d+|\#\d+|wiki:\w+\#?\w+|changeset:\w+)(?:$|\W)/).flatten

		# Do we have at least one possible reference?
		return unless refs.length > 0

		refs.each do |ref|
			debug "We're out to handle '#{ref}'"
		
			url, title = expand_reference(ref, m.target)

			return unless url

			# Try to address the message to the right person
			if m.message =~ /^(\S+)[:,]/
				addressee = "#{$1}: "
			else
				addressee = "#{m.sourcenick}: "
			end
			
			# So we have a valid URL, and addressee, and now we just have to... speak!
			m.reply "#{addressee}#{ref} is #{url}" + (title.nil? ? '' : " \"#{title}\"")
		end
	end

	def redmineinfo(m, params)
		debug("Handling redmineinfo request; params is #{params.inspect}")
		return unless m.kind_of?(PrivMessage)
		m.reply "I can't do redmineinfo in private yet" and return unless m.public?

		url, title = expand_reference(params[:ref], m.target)
		
		if url.nil?
			# Error!  The user-useful error message is in the 'title'
			m.reply "#{m.sourcenick}: #{title}" if title
		else
			m.reply "#{m.sourcenick}: #{params[:ref]} is #{url}" + (title ? " \"#{title}\"" : '')
		end
	end
	
	private
	# Parse the Redmine reference given in +ref+, and try to construct a URL
	# from +base+ to the resource.  Returns an array containing the URL
	# and a type symbol (one of :changeset, :ticket, or :wiki), as a pair (eg
	# ['http://blah/ticket/1', :ticket])
	#
	def ref_into_url(base, ref)
		case ref
			when /\[(\d+)\]/:
				[rev_url(base, $1), :changeset]
			
			when /r(\d+)/:
				[rev_url(base, $1), :changeset]
		
                        when /changeset:(\w+)/:
                                [rev_url(base, $1), :changeset]
	
			when /\#(\d+)/:
				[bug_url(base, $1), :ticket]

                        when /wiki:(\w+\#?\w+)/:
                                [wiki_url(base, $1), :wiki]
		end
	end

	# Return the CSS query that will extract the 'title' (or at least some
	# sort of sensible information) out of a HTML document of the given
	# reftype.
	def css_query_for(reftype)
		case reftype
			when :wiki:
				nil
			when :changeset:
				'#searchable p'
			when :ticket:
				'h2.summary'
			else
				warning "Unknown reftype: #{reftype}"; nil
		end
	end
	
	# Return the base URL for the channel (passed in as +target+), or +nil+
	# if the channel isn't in the channelmap.
	#
	def base_url(target)
		e = @bot.config['redmine_urls.channelmap'].find {|c| c =~ /^#{target}:/ }
		e.gsub(/^#{target}:/, '') unless e.nil?
	end
	
	def rev_url(base_url, num)
		base_url + '/repositories/revision/puppet/' + num
	end
	
	def bug_url(base_url, num)
		base_url + '/issues/show/' + num
	end
	
	def wiki_url(base_url, page)
		base_url + '/wiki/' + page
	end

	# Turn a string (which is, presumably, a Redmine reference of some sort)
	# into a URL and, if possible, a title.
	#
	# Since the URL associated with a Redmine reference is specific to a particular
	# Redmine instance, you also need to pass the channel into expand_reference,
	# so it knows which channel (and hence which Redmine instance) you're
	# talking about.
	#
	# Returns an array of [url, title].  If url is nil, then the reference
	# was of an invalid type or dereferenced to an invalid URL.  In that
	# case, title will be an error message.  Otherwise, url will be a string
	# URL and title should be a brief useful description of the URL (although
	# it may well be nil if we don't know how to get a title for that type of
	# Trac reference).
	#
	def expand_reference(ref, channel)
		debug "Expanding reference #{ref} in #{channel}"
		base = base_url(channel)

		# If we're not in a channel with a mapped base URL...
		return [nil, "I don't know about Redmine URLs for this channel"] if base.nil?

		debug "Base URL for #{channel} is #{base}"
		begin
			url, reftype = ref_into_url(base, ref)
			css_query = css_query_for(reftype)

			content = unless css_query.nil?
				# Rip up the page and tell us what you saw
				page_element_contents(url, css_query)
			else
				# We don't know how to get meaningful info out of this page, so
				# just validate that it actually loads
				page_element_contents(url, 'h1')
				nil
			end
			
			[url, content]
		rescue InvalidRedmineUrl => e
			error("InvalidRedmineUrl returned: #{e.message}")
			return [nil, "I'm afraid I don't understand '#{ref}' or I can't find a page for it.  Sorry."]
		rescue Exception => e
			error("Error (#{e.class}) while fetching URL #{url}: #{e.message}")
			e.backtrace.each {|l| error(l)}
			return [nil, "#{url} #{e.message} #{e.class} - An error occured while I was trying to look up the URL.  Sorry."]
		end
	end

	# Return the contents of the first element that matches +css_query+ in
	# the given +url+, or else raise InvalidRedmineUrl if the page doesn't
	# respond with 200 OK.
	#
	def page_element_contents(url, css_query)
		parts = URI.parse(url)
		resp = nil
		ssl = @bot.config['redmine_urls.https']
		b_auth = @bot.config['redmine_urls.basic_auth']
		b_auth_uname = @bot.config['redmine_urls.basic_auth_username']
		b_auth_pword = @bot.config['redmine_urls.basic_auth_password']
		debug("Setup: https: #{ssl}, auth: #{@bot.config['redmine_urls.basic_auth']} username: #{@bot.config['redmine_urls.basic_auth_username']} password: #{@bot.config['redmine_urls.basic_auth_password']}")
		if @bot.config['redmine_urls.https']
			port = 443
		else
			port = 80
		end
		http = Net::HTTP.new(parts.host, port)
		http.use_ssl = @bot.config['redmine_urls.https']
		debug("use_ssl is #{http.use_ssl}")
		http.start do |http| 
			request = Net::HTTP::Get.new(parts.path)
			if @bot.config['redmine_urls.basic_auth']
				debug("trying to use http basic auth")
				request.basic_auth @bot.config['redmine_urls.basic_auth_username'], @bot.config['redmine_urls.basic_auth_password']
			end
			resp = http.request(request)
		end

		debug("Response object is #{resp.inspect} for #{url}")
		raise InvalidRedmineUrl.new("#{url} returned #{resp.code} #{resp.message}") unless resp.code == '200'
		elem = Hpricot.parse(resp.body).search(css_query).first
		unless elem
			warning("Didn't find '#{css_query}' in response #{resp.body}")
			return
		end
		debug("Found '#{elem.inner_text}' with '#{css_query}'")
		elem.inner_text.gsub("\n", ' ').gsub(/\s+/, ' ').strip
	end
end

plugin = RedmineUrlsPlugin.new
plugin.map 'redmineinfo :ref'
