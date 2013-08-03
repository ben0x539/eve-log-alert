INTEL_LOG_DIR    = "#{ENV['HOME']}/EVE/logs/Chatlogs"
INTEL_LOG_PREFIX = "/DEK.CFC"
GAME_LOG_DIR     = "#{ENV['HOME']}/EVE/logs/Gamelogs"

require 'rb-inotify'

Dir.chdir(File.dirname(__FILE__))

def find_latest(dir)
  latest, latest_mtime = nil

  Dir.foreach(dir) do |file|
    file = "#{dir}/#{file}"
    next unless File.file?(file)
    mtime = File.mtime(file)
    next unless yield(file, mtime)
    latest, latest_mtime = file, mtime if !latest || mtime > latest_mtime
  end

  raise "no matching log file found in #{dir}" unless latest

  latest
end

def is_log_for(path, char_name)
  ok = nil
  File.open(path) do |file|
    file.gets; file.gets
    s = file.gets
    ok = !! s.include?("Listener: #{char_name}")
  end
  ok
end


def from_this_week(date)
  Time.now - date < 7*24*60*60
end

def listen(notifier, filename, *open_args, on_close)
  f = File.open(filename, *open_args)
  f.seek(0, IO::SEEK_END)
  line_buf = ''
  notifier.watch(filename, :modify, :close_write) do |event|
    if event.flags.include?(:close_write)
      on_close && on_close.call(event)
    else
      new_text = f.read()
      unless new_text.encoding == Encoding::UTF_8
        new_text = new_text.encode(Encoding::UTF_8)
      end
      line_buf << new_text
      *lines, line_buf = line_buf.split(/\r?\n/, -1)
      line_buf ||= ''
      yield lines
    end
  end
  f
end

def send_notification(msg)
  system "notify-send", msg
  pid = Process.spawn("aplay", "alertsound",
                      [:in, :out, :err] => :close)
  Process.detach(pid)
end

class GameLogState
  FANCY_RAT_NAMES = ["Dread Gurista"]
  NO_INC_DMG_TIME =20
  NO_OUT_DMG_TIME = 40
  IDLE_TIME = 20

  def initialize()
    @last_incoming =
    @last_outgoing =
    @last_msg      =
      Time.now
    @last_idle = @last_dg = Time.at(0)
    @dmg_taken = []
    @under_attack_since = nil
  end

  def feed(line)
    @now = Time.now
    return unless
      line.match(/\[ \d{4}\.\d\d\.\d\d \d\d:\d\d:\d\d \] \(combat\) /)
    line = line[33..-1]
    line.gsub!(/<[^>]+>/, '')

    check_fancy_rat(line)

    note_damage(line)
  end

  def check_fancy_rat(line)
    if FANCY_RAT_NAMES.any? {|r| line.include?(r)} && @now - @last_dg > 300
      send_notification("Dread Gurista spotted")
      @last_msg = @last_dg = @now
    end
  end

  def idle()
    @now = Time.now
    last = [@last_incoming, @last_outgoing].max
    if @now - last > IDLE_TIME && @now - @last_idle > 120
      notify("idling")
      @last_idle = @now
      @under_attack_since = nil
    end
  end

  private

  def notify(msg, timeout = 30)
    if @now - @last_msg > timeout
      send_notification(msg)
      @last_msg = @now
    end
  end

  def note_damage(line)
    if m = line.match(/^(\d+) from (.*?) -/)
      return inc(m[2], m[1].to_i)
    elsif m = line.match(/^(.*?) misses you completely/)
      return inc(m[1], 0)
    elsif m = line.match(/^(\d+) to (.*?) -/)
      return out(m[2], m[1].to_i)
    elsif m = line.match(/^Your (.*?) misses (.*?) completely/)
      return out(m[2], 0)
    end

    return false
  end

  def inc(who, dmg)
    @last_incoming = @now
    @dmg_taken.delete_if {|when_, _| @now - when_ > 10}
    @dmg_taken << [@now, dmg]
    sum = @dmg_taken.inject(0) {|acc, (_, dmg_)| acc+dmg_}
    @under_attack_since ||= @now
    if @last_incoming > @last_outgoing + NO_OUT_DMG_TIME &&
       @now - @under_attack_since > 20
      notify("receiving damage, but none dealt for #{NO_OUT_DMG_TIME}s")
    elsif dmg > 150
      notify("took #{dmg} in one shot")
    elsif sum / 10 > 50
      notify("taking >50 dps")
    end
  end
  def out(who, dmg)
    @last_outgoing = @now
    if @last_incoming + NO_INC_DMG_TIME < @last_outgoing
      notify("dealing damage, but none received for #{NO_INC_DMG_TIME}s")
    end
  end
end

game_log_state = GameLogState.new

char_name = ARGV.shift.encode(Encoding::UTF_8)
system_names = ARGV.map{|arg| /\b#{arg}\S*/i }
if system_names.empty?
  raise "no system names given"
end

intel_filename = find_latest(INTEL_LOG_DIR) { |path, date|
  from_this_week(date) && path.include?(INTEL_LOG_PREFIX)
}

game_filename = find_latest(GAME_LOG_DIR) { |path, date|
  from_this_week(date) && path.end_with?(".txt") &&
    is_log_for(path, char_name)
}

ping_at_exit = true
Signal.trap('INT') do
  ping_at_exit = false
  exit
end
at_exit do
  send_notification("exiting") if ping_at_exit
end

files = []
last_alert_sound = 0
done = false
begin
  files << notifier = INotify::Notifier.new
  notifier_io = notifier.to_io
  files << listen(notifier, intel_filename, "rb:UTF-16LE",
                  lambda do done = false end) do |lines|
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
      # "<feff>[ 2013.04.15 14:53:52 ] "
      line.slice!(0, 25)
    end
    unless lines.empty?
      now = Time.now.to_i
      if now - last_alert_sound > 5
        send_notification("#{INTEL_LOG_PREFIX}: #{lines.join("\n")}")
        last_alert_sound = now
      end
    end
  end
  files << listen(notifier, game_filename, nil) do |lines|
    lines.each do |line|

      game_log_state.feed(line)
    end
  end
  loop do
    break if done
    if select([notifier_io], [], [notifier_io], 5)
      notifier.process
    else
      game_log_state.idle
    end
  end
ensure
  files.each do |f| f.close end
end

