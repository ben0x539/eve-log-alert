LOG_DIR     = "#{ENV['HOME']}/EVE/logs/Chatlogs"
LOG_PREFIX  = "DEKCFC"

require 'rb-inotify'

Dir.chdir(File.dirname(__FILE__))

latest, latest_mtime = nil

Dir.foreach(LOG_DIR) do |file|
  next unless file.start_with?(LOG_PREFIX)
  file = "#{LOG_DIR}/#{file}"
  mtime = File.mtime(file)
  latest, latest_mtime = file, mtime if !latest || mtime > latest_mtime
end

raise "no matching log file found" unless latest

filename = latest

system_names = ARGV.map{|arg| /\b#{arg}\S*/i }
if system_names.empty?
  raise "no system names given"
end

last_alert_sound = 0
File.open(filename, "rb:UTF-16LE") do |file|
  file.seek(0, IO::SEEK_END)
  notifier = INotify::Notifier.new
  line_buf = ''
  notifier.watch(filename, :modify, :close_write) do |event|
    if event.flags.include?(:close_write)
      notifier.stop
    else
      line_buf << file.read().encode("UTF-8")
      *lines, line_buf = line_buf.split(/\r?\n/, -1)
      lines.delete_if { |line|
        line_ = line[(line.index('>') or 0)+2..-1]
        !system_names.any? { |sys|
          if sys.match(line)
            line__ = line_.gsub(sys, '')
            line__.gsub!(/[\s.,!]+/, '')
            ! /(cl(ea)?r|status\??|blue)$/i.match(line__)
          end
        }
      }
      lines.each do |line|
        # "[ 2013.04.15 14:53:52 ] "
        line.slice!(0, 25)
      end
      unless lines.empty?
        system "notify-send", "#{LOG_PREFIX}: #{lines.join("\n")}"
        now = Time.now.to_i
        if now - last_alert_sound > 5
          last_alert_sound = now
          pid = Process.spawn("aplay", "alertsound",
                              [:in, :out, :err] => :close)
          Process.detach(pid)
        end
      end
    end
  end
  notifier.run
end
