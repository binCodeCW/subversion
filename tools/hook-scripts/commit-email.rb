#!/usr/bin/env ruby

require "optparse"
require "ostruct"
require "stringio"
require "tempfile"
require "time"
require "net/smtp"
require "socket"

SMTP_PORT = 25
KILO_SIZE = 1000
DEFAULT_MAX_SIZE = "100M"

class OptionParser
  class CannotCoexistOption < ParseError
    const_set(:Reason, 'cannot coexist option'.freeze)
  end
end

def parse_args(args)
  options = OpenStruct.new
  options.to = []
  options.error_to = []
  options.from = nil
  options.from_domain = nil
  options.add_diff = true
  options.max_size = parse_size(DEFAULT_MAX_SIZE)
  options.repository_uri = nil
  options.rss_path = nil
  options.rss_uri = nil
  options.multi_project = false
  options.show_path = false
  options.trunk_path = "trunk"
  options.branches_path = "branches"
  options.tags_path = "tags"
  options.name = nil
  options.use_utf7 = false
  options.server = "localhost"
  options.port = SMTP_PORT

  opts = OptionParser.new do |opts|
    opts.banner += " REPOSITORY_PATH REVISION TO"

    opts.separator ""
    opts.separator "E-mail related options:"

    opts.on("-sSERVER", "--server=SERVER",
            "Use SERVER as SMTP server (#{options.server})") do |server|
      options.server = server
    end

    opts.on("-pPORT", "--port=PORT", Integer,
            "Use PORT as SMTP port (#{options.port})") do |port|
      options.port = port
    end

    opts.on("-tTO", "--to=TO", "Add TO to To: address") do |to|
      options.to << to unless to.nil?
    end

    opts.on("-eTO", "--error-to=TO",
            "Add TO to To: address when an error occurs") do |to|
      options.error_to << to unless to.nil?
    end

    opts.on("-fFROM", "--from=FROM", "Use FROM as from address") do |from|
      if options.from_domain
        raise OptionParser::CannotCoexistOption,
              "cannot coexist with --from-domain"
      end
      options.from = from
    end

    opts.on("--from-domain=DOMAIN",
            "Use author@DOMAIN as from address") do |domain|
      if options.from
        raise OptionParser::CannotCoexistOption,
              "cannot coexist with --from"
      end
      options.from_domain = domain
    end

    opts.separator ""
    opts.separator "Output related options:"

    opts.on("--[no-]multi-project",
            "Treat as multi-project hosting repository") do |bool|
      options.multi_project = bool
    end

    opts.on("--name=NAME", "Use NAME as repository name") do |name|
      options.name = name
    end

    opts.on("--[no-]show-path",
            "Show commit target path") do |bool|
      options.show_path = bool
    end

    opts.on("--trunk-path=PATH",
            "Treat PATH as trunk path (#{options.trunk_path})") do |path|
      options.trunk_path = path
    end

    opts.on("--branches-path=PATH",
            "Treat PATH as branches path (#{options.branches_path})") do |path|
      options.branches_path = path
    end

    opts.on("--tags-path=PATH",
            "Treat PATH as tags path (#{options.tags_path})") do |path|
      options.tags_path = path
    end

    opts.on("-rURI", "--repository-uri=URI",
            "Use URI as URI of repository") do |uri|
      options.repository_uri = uri
    end

    opts.on("-n", "--no-diff", "Don't add diffs") do |diff|
      options.add_diff = false
    end

    opts.on("--max-size=SIZE",
            "Limit mail body size to SIZE",
            "G/GB/M/MB/K/KB/B units are available",
            "(#{format_size(options.max_size)})") do |max_size|
      begin
        options.max_size = parse_size(max_size)
      rescue ArgumentError
        raise OptionParser::InvalidArgument, max_size
      end
    end

    opts.on("--no-limit-size",
            "Don't limit mail body size",
            "(#{limited_size?(options.max_size)})") do |not_limit_size|
      options.max_size = -1
    end

    opts.on("--[no-]utf7",
            "Use UTF-7 encoding for mail body instead",
            "of UTF-8 (#{options.use_utf7})") do |use_utf7|
      options.use_utf7 = use_utf7
    end

    opts.separator ""
    opts.separator "RSS related options:"

    opts.on("--rss-path=PATH", "Use PATH as output RSS path") do |path|
      options.rss_path = path
    end

    opts.on("--rss-uri=URI", "Use URI as output RSS URI") do |uri|
      options.rss_uri = uri
    end

    opts.separator ""
    opts.separator "Other options:"

    opts.on("-IPATH", "--include=PATH", "Add PATH to load path") do |path|
      $LOAD_PATH.unshift(path)
    end

    opts.on_tail("--help", "Show this message") do
      puts opts
      exit!
    end
  end

  opts.parse!(args)

  options
end

def limited_size?(size)
  size > 0
end

def format_size(size)
  return "no limit" unless limited_size?(size)
  return "#{size}B" if size < KILO_SIZE
  size /= KILO_SIZE.to_f
  return "#{size}KB" if size < KILO_SIZE
  size /= KILO_SIZE.to_f
  return "#{size}MB" if size < KILO_SIZE
  size /= KILO_SIZE.to_f
  "#{size}GB"
end

def parse_size(size)
  case size
  when /\A(.+?)GB?\z/i
    Float($1) * KILO_SIZE ** 3
  when /\A(.+?)MB?\z/i
    Float($1) * KILO_SIZE ** 2
  when /\A(.+?)KB?\z/i
    Float($1) * KILO_SIZE
  when /\A(.+?)B?\z/i
    Float($1)
  else
    raise ArgumentError, "invalid size: #{size.inspect}"
  end
end

def parse(argv=ARGV)
  argv = argv.dup
  options = parse_args(argv)
  repos, revision, to, *rest = argv

  [repos, revision, to, options]
end

def make_body(info, options)
  body = ""
  body << "#{info.author}\t#{format_time(info.date)}\n"
  body << "\n"
  body << "  New Revision: #{info.revision}\n"
  body << "\n"
  body << added_dirs(info)
  body << added_files(info)
  body << copied_dirs(info)
  body << copied_files(info)
  body << deleted_dirs(info)
  body << deleted_files(info)
  body << modified_dirs(info)
  body << modified_files(info)
  body << "\n"
  body << "  Log:\n"
  info.log.each_line do |line|
    body << "    #{line}"
  end
  body << "\n"
  body << change_info(info, options.repository_uri, options.add_diff)
  body
end

def format_time(time)
  time.strftime('%Y-%m-%d %X %z (%a, %d %b %Y)')
end

def changed_items(title, type, items)
  rv = ""
  unless items.empty?
    rv << "  #{title} #{type}:\n"
    if block_given?
      yield(rv, items)
    else
      rv << items.collect {|item| "    #{item}\n"}.join('')
    end
  end
  rv
end

def changed_files(title, files, &block)
  changed_items(title, "files", files, &block)
end

def added_files(info)
  changed_files("Added", info.added_files)
end

def deleted_files(info)
  changed_files("Removed", info.deleted_files)
end

def modified_files(info)
  changed_files("Modified", info.updated_files)
end

def copied_files(info)
  changed_files("Copied", info.copied_files) do |rv, files|
    rv << files.collect do |file, from_file, from_rev|
      <<-INFO
    #{file}
      (from rev #{from_rev}, #{from_file})
INFO
    end.join("")
  end
end

def changed_dirs(title, files, &block)
  changed_items(title, "directories", files, &block)
end

def added_dirs(info)
  changed_dirs("Added", info.added_dirs)
end

def deleted_dirs(info)
  changed_dirs("Removed", info.deleted_dirs)
end

def modified_dirs(info)
  changed_dirs("Modified", info.updated_dirs)
end

def copied_dirs(info)
  changed_dirs("Copied", info.copied_dirs) do |rv, dirs|
    rv << dirs.collect do |dir, from_dir, from_rev|
      "    #{dir} (from rev #{from_rev}, #{from_dir})\n"
    end.join("")
  end
end


CHANGED_TYPE = {
  :added => "Added",
  :modified => "Modified",
  :deleted => "Deleted",
  :copied => "Copied",
  :property_changed => "Property changed",
}

CHANGED_MARK = Hash.new("=")
CHANGED_MARK[:property_changed] = "_"

def change_info(info, uri, add_diff)
  result = changed_dirs_info(info, uri)
  result = "\n#{result}" unless result.empty?
  result << "\n"
  diff_info(info, uri, add_diff).each do |key, infos|
    infos.each do |desc, link|
      result << "#{desc}\n"
    end
  end
  result
end

def changed_dirs_info(info, uri)
  rev = info.revision
  (info.added_dirs.collect do |dir|
     "  Added: #{dir}\n"
   end + info.copied_dirs.collect do |dir, from_dir, from_rev|
     <<-INFO
  Copied: #{dir}
    (from rev #{from_rev}, #{from_dir})
INFO
   end + info.deleted_dirs.collect do |dir|
     <<-INFO
  Deleted: #{dir}
    % svn ls #{[uri, dir].compact.join("/")}@#{rev - 1}
INFO
   end + info.updated_dirs.collect do |dir|
     "  Modified: #{dir}\n"
   end).join("\n")
end

def diff_info(info, uri, add_diff)
  info.diffs.collect do |key, values|
    [
      key,
      values.collect do |type, value|
        args = []
        rev = info.revision
        case type
        when :added
          command = "cat"
        when :modified, :property_changed
          command = "diff"
          args.concat(["-r", "#{info.revision - 1}:#{info.revision}"])
        when :deleted
          command = "cat"
          rev -= 1
        when :copied
          command = "cat"
        else
          raise "unknown diff type: #{value.type}"
        end

        command += " #{args.join(' ')}" unless args.empty?

        link = [uri, key].compact.join("/")

        line_info = "+#{value.added_line} -#{value.deleted_line}"
        desc = <<-HEADER
  #{CHANGED_TYPE[value.type]}: #{key} (#{line_info})
#{CHANGED_MARK[value.type] * 67}
HEADER

        if add_diff
          desc << value.body
        else
          desc << <<-CONTENT
    % svn #{command} #{link}@#{rev}
CONTENT
        end

        [desc, link]
      end
    ]
  end
end

def make_header(to, from, info, options, body_encoding, body_encoding_bit)
  headers = []
  headers << x_author(info)
  headers << x_revision(info)
  headers << x_repository(info)
  headers << x_id(info)
  headers << "MIME-Version: 1.0"
  headers << "Content-Type: text/plain; charset=#{body_encoding}"
  headers << "Content-Transfer-Encoding: #{body_encoding_bit}"
  headers << "From: #{from}"
  headers << "To: #{to.join(', ')}"
  headers << "Subject: #{make_subject(options.name, info, options)}"
  headers << "Date: #{Time.now.rfc2822}"
  headers.find_all do |header|
    /\A\s*\z/ !~ header
  end.join("\n")
end

def detect_project(info, options)
  return nil unless options.multi_project
  project = nil
  info.paths.each do |path, from_path,|
    [path, from_path].compact.each do |target_path|
      first_component = target_path.split("/", 2)[0]
      project ||= first_component
      return nil if project != first_component
    end
  end
  project
end

def affected_paths(project, info, options)
  paths = []
  [nil, :branches_path, :tags_path].each do |target|
    prefix = [project]
    prefix << options.send(target) if target
    prefix = prefix.compact.join("/")
    sub_paths = info.sub_paths(prefix)
    if target.nil?
      sub_paths = sub_paths.find_all do |sub_path|
        sub_path == options.trunk_path
      end
    end
    paths.concat(sub_paths)
  end
  paths.uniq
end

def make_subject(name, info, options)
  subject = ""
  project = detect_project(info, options)
  subject << "#{name} " if name
  revision_info = "r#{info.revision}"
  if options.show_path
    _affected_paths = affected_paths(project, info, options)
    unless _affected_paths.empty?
      revision_info = "(#{_affected_paths.join(',')}) #{revision_info}"
    end
  end
  if project
    subject << "[#{project} #{revision_info}] "
  else
    subject << "#{revision_info}: "
  end
  subject << info.log.lstrip.to_a.first.to_s.chomp
  NKF.nkf("-WM", subject)
end

def x_author(info)
  "X-SVN-Author: #{info.author}"
end

def x_revision(info)
  "X-SVN-Revision: #{info.revision}"
end

def x_repository(info)
  # "X-SVN-Repository: #{info.path}"
  "X-SVN-Repository: XXX"
end

def x_id(info)
  "X-SVN-Commit-Id: #{info.entire_sha256}"
end

def utf8_to_utf7(utf8)
  require 'iconv'
  Iconv.conv("UTF-7", "UTF-8", utf8)
rescue InvalidEncoding
  begin
    Iconv.conv("UTF7", "UTF8", utf8)
  rescue Exception
    nil
  end
rescue Exception
  nil
end

def truncate_body(body, max_size, use_utf7)
  return body if body.size < max_size

  truncated_body = body[0, max_size]
  truncated_message = "... truncated to #{format_size(max_size)}\n"
  truncated_message = utf8_to_utf7(truncated_message) if use_utf7
  truncated_message_size = truncated_message.size

  lf_index = truncated_body.rindex(/(?:\r|\r\n|\n)/)
  while lf_index
    if lf_index + truncated_message_size < max_size
      truncated_body[lf_index, max_size] = "\n#{truncated_message}"
      break
    else
      lf_index = truncated_body.rindex(/(?:\r|\r\n|\n)/, lf_index - 1)
    end
  end

  truncated_body
end

def make_mail(to, from, info, options)
  utf8_body = make_body(info, options)
  utf7_body = nil
  utf7_body = utf8_to_utf7(utf8_body) if options.use_utf7
  if utf7_body
    body = utf7_body
    encoding = "utf-7"
    bit = "7bit"
  else
    body = utf8_body
    encoding = "utf-8"
    bit = "8bit"
  end

  max_size = options.max_size
  if limited_size?(max_size)
    body = truncate_body(body, max_size, !utf7_body.nil?)
  end

  make_header(to, from, info, options, encoding, bit) + "\n" + body
end

def sendmail(to, from, mail, server=nil, port=nil)
  server ||= "localhost"
  port ||= SMTP_PORT
  Net::SMTP.start(server, port) do |smtp|
    smtp.open_message_stream(from, to) do |f|
      f.print(mail)
    end
  end
end

def output_rss(name, file, rss_uri, repos_uri, info)
  prev_rss = nil
  begin
    if File.exist?(file)
      File.open(file) do |f|
        prev_rss = RSS::Parser.parse(f)
      end
    end
  rescue RSS::Error
  end

  File.open(file, "w") do |f|
    f.print(make_rss(prev_rss, name, rss_uri, repos_uri, info).to_s)
  end
end

def make_rss(base_rss, name, rss_uri, repos_uri, info)
  RSS::Maker.make("1.0") do |maker|
    maker.encoding = "UTF-8"

    maker.channel.about = rss_uri
    maker.channel.title = rss_title(name || repos_uri)
    maker.channel.link = repos_uri
    maker.channel.description = rss_title(name || repos_uri)
    maker.channel.dc_date = info.date

    if base_rss
      base_rss.items.each do |item|
        item.setup_maker(maker)
      end
    end

    diff_info(info, repos_uri, true).each do |name, infos|
      infos.each do |desc, link|
        item = maker.items.new_item
        item.title = name
        item.description = info.log
        item.content_encoded = "<pre>#{h(desc)}</pre>"
        item.link = link
        item.dc_date = info.date
        item.dc_creator = info.author
      end
    end

    maker.items.do_sort = true
    maker.items.max_size = 15
  end
end

def rss_title(name)
  "Repository of #{name}"
end

def rss_items(items, info, repos_uri)
  diff_info(info, repos_uri).each do |name, infos|
    infos.each do |desc, link|
      items << [link, name, desc, info.date]
    end
  end

  items.sort_by do |uri, title, desc, date|
    date
  end.reverse
end

def main
  repos, revision, to, options = parse

  require "svn/info"
  info = Svn::Info.new(repos, revision)
  from = options.from
  from ||= "#{info.author}@#{options.from_domain}".sub(/@\z/, '')
  to = [to, *options.to].compact
  sendmail(to, from, make_mail(to, from, info, options),
           options.server, options.port)

  if options.repository_uri and
      options.rss_path and
      options.rss_uri
    require "rss/1.0"
    require "rss/dublincore"
    require "rss/content"
    require "rss/maker"
    include RSS::Utils
    output_rss(options.name,
               options.rss_path,
               options.rss_uri,
               options.repository_uri,
               info)
  end
end

begin
  main
rescue Exception => error
  argv = ARGV.dup
  to = []
  subject = "Error"
  from = "#{ENV['USER']}@#{Socket.gethostname}"
  server = nil
  port = nil
  begin
    _, _, _to, options = parse(argv)
    to = [_to]
    to = options.error_to unless options.error_to.empty?
    from = options.from || from
    subject = "#{options.name}: #{subject}" if options.name
    server = options.server
    port = options.port
  rescue OptionParser::MissingArgument
    argv.delete_if {|arg| $!.args.include?(arg)}
    retry
  rescue OptionParser::ParseError
    if to.empty?
      _, _, _to, *_ = ARGV.reject {|arg| /^-/.match(arg)}
      to = [_to]
    end
  end

  detail = <<-EOM
#{error.class}: #{error.message}
#{error.backtrace.join("\n")}
EOM
  to = to.compact
  if to.empty?
    STDERR.puts detail
  else
    sendmail(to, from, <<-MAIL, server, port)
MIME-Version: 1.0
Content-Type: text/plain; charset=us-ascii
Content-Transfer-Encoding: 7bit
From: #{from}
To: #{to.join(', ')}
Subject: #{subject}
Date: #{Time.now.rfc2822}

#{detail}
MAIL
  end
end
