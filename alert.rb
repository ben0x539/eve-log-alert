INTEL_LOG_DIR    = "#{ENV['HOME']}/EVE/logs/Chatlogs"
INTEL_LOG_PREFIX = "DEK.CFC"
GAME_LOG_DIR     = "#{ENV['HOME']}/EVE/logs/Gamelogs"

require 'rb-inotify'

Dir.chdir(File.dirname(__FILE__))

UNIVERSE_DB_PATH = "universeDataDx.db"
has_db = File.exists?(UNIVERSE_DB_PATH) &&
  begin
    require 'sqlite3'
  rescue LoadError
    false
  end

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

def find_open_chatlog(dir, prefix)
  path_prefix = "#{dir}/#{prefix}_"
  found = nil
  Dir.foreach('/proc') do |pid|
    next unless pid.match(/^\d+$/)
    next unless File.read("/proc/#{pid}/cmdline").match(/([\/\\]|^)bin[\/\\]ExeFile.exe/i)
    begin
      fds = "/proc/#{pid}/fd"
      Dir.foreach(fds) do |fd|
        next unless fd.match(/^\d+$/)
        path = File.readlink("#{fds}/#{fd}")
        return path if path.start_with?(path_prefix)
      end
    rescue Errno::EACCES
    end
  end
  nil
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
  puts "#{Time.now.strftime('%H:%M')}: #{msg}"
  system "notify-send", msg
  pid = Process.spawn("aplay", "alertsound",
                      [:in, :out, :err] => :close)
  Process.detach(pid)
end

$currently_panicking = nil
def panic(msg)
  puts "#{Time.now.strftime('%H:%M')}: #{msg}"
  system "notify-send", msg
  return if $currently_panicking
  Thread.new do
    file = "frogsiren"
    file "alertsound" unless File.exists?(file)
    loop do
      $currently_panicking = Process.spawn("aplay", file,
                          [:in, :out, :err] => :close)
      Process.wait($currently_panicking)
      break unless $currently_panicking
    end
  end
end

class GameLogState
  FANCY_RAT_NAMES = ["Dread Gurista"]
  NO_INC_DMG_TIME = 20
  NO_OUT_DMG_TIME = 40
  IDLE_TIME = 20

  def initialize(char_name)
    @char_name = char_name
    @last_incoming =
    @last_outgoing =
    @last_msg      =
      Time.now
    @last_idle = @last_dg = Time.at(0)
    @dmg_taken = []
    @under_attack_since = nil
    @docked = true
  end

  def feed(line)
    @now = Time.now
    if line.match(/\[ \d{4}\.\d\d\.\d\d \d\d:\d\d:\d\d \] \(notify\) Your docking request has been accepted/)
      dock(true)
    elsif line.match(/\[ \d{4}\.\d\d\.\d\d \d\d:\d\d:\d\d \] \(None\) Undocking from /)
      dock(false)
    end
    return unless
      line.match(/\[ \d{4}\.\d\d\.\d\d \d\d:\d\d:\d\d \] \(combat\) /)
    @docked = false
    line = line[33..-1]
    line.gsub!(/<[^>]+>/, '')

    check_player_attack(line)

    check_fancy_rat(line)

    note_damage(line)
  end

  def idle()
    return if @docked
    @now = Time.now
    last = [@last_incoming, @last_outgoing].max
    if @now - last > IDLE_TIME && @now - @last_idle > 120
      notify("idling")
      @last_idle = @now
      @under_attack_since = nil
    end
  end

  def docked?()
    @docked
  end

  private

  def dock(docked)
    @docked = docked
    if docked
      notify_("docking up; disabling notifications")
    else
      notify_("undocking; enabling notifications")
      @last_idle = @now = Time.now
    end
  end

  def notify_(msg)
      send_notification("#{@char_name}: #{msg}")
  end

  def notify_player_attack(msg)
      panic("#{@char_name}: #{msg}")
  end

  def notify(msg, timeout = 30)
    if @now - @last_msg > timeout
      notify_(msg)
      @last_msg = @now
    end
  end

  def check_player_attack(line)
    # idea here is to not match plain NPC names like "Dire Pithi Whatever"
    # but match player names that are likely to have an overview-pack
    # specific sort of bracket or &lt; hyphen or whatever in them for corp tags
    # or shiptypes or whatever
    line_noise = "[-\\[<&;(]"
    case line
    when /Warp scramble attempt from .*?#{line_noise}/
      notify_player_attack("tackled by player!")
    when /belonging to .*? misses you completely/
      notify_player_attack("shot by player!")
    when /\d+ from .*?#{line_noise}.*? - .*? - [A-Za-z ]+$/
      notify_player_attack("shot by player!")
    end
  end

  def check_fancy_rat(line)
    if FANCY_RAT_NAMES.any? {|r| line.include?(r)} && @now - @last_dg > 300
      notify_("Dread Gurista spotted")
      @last_msg = @last_dg = @now
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
    @dmg_taken.delete_if {|when_, _| @now - when_ > 40}
    @dmg_taken << [@now, dmg]
    sum = @dmg_taken.inject(0) {|acc, (_, dmg_)| acc+dmg_}
    @under_attack_since ||= @now
    if @last_incoming > @last_outgoing + NO_OUT_DMG_TIME &&
       @now - @under_attack_since > 20
      notify("receiving damage, but none dealt for #{NO_OUT_DMG_TIME}s")
    elsif dmg > 150
      notify("took #{dmg} in one shot")
    elsif sum / 40 > 60
      notify("taking >60 dps")
    end
  end
  def out(who, dmg)
    @last_outgoing = @now
    if @last_incoming + NO_INC_DMG_TIME < @last_outgoing
      notify("dealing damage, but none received for #{NO_INC_DMG_TIME}s")
    end
  end
end

def systems_by_distance(distance)
  db = SQLite3::Database.new(UNIVERSE_DB_PATH)
  systems = {}
  distance.each do |sys, dist|
    found = nil
    db.execute(<<-END, sys, dist) do |row|
      WITH RECURSIVE
        "neighbors" ("name", "distance") AS (
          SELECT "solarSystemName", 0
            FROM "mapSolarSystems"
            WHERE "solarSystemName" = ?
          UNION
          SELECT "t"."solarSystemName", "n"."distance" + 1
            FROM "neighbors" "n",
                "mapSolarSystems" "f"
                JOIN "mapSolarSystemJumps" "j"
                     ON "f"."solarSystemID" = "j"."fromSolarSystemID"
                JOIN "mapSolarSystems" "t"
                     ON "j"."toSolarSystemID" = "t"."solarSystemID"
            WHERE "f"."solarSystemName" = "n"."name" AND "n"."distance" < ?)
      SELECT "name", "distance" FROM "neighbors";
    END
      name = row[0]
      distance = row[1]
      mangled_name = name.dup
      mangled_name.gsub!(/^(.{3,})-.*/, '\1') # VFK, ZOY etc
      mangled_name.gsub!(/^(..-).*/, '\1')    # JU-, 0P- etc
      mangled_name.gsub!(/^(....).*/, '\1')   # Named systems I guess
      mangled_name.gsub!(/[I1]/, "[I1]")      # I30-  -> 130
      mangled_name.gsub!(/[O0]/, "[O0]")      # 209G -> 2O9G
      mangled_name.gsub!(/[S5]/, "[S5]")      # 209G -> 2O9G
      mangled_name.gsub!(/[G6]/, "[G6]")      # 2O96 -> 2O9G
      found = (systems[name] ||= [sys, distance, mangled_name])
    end
    raise "No system found: #{sys}" unless found
  end
  result = []
  systems.each_pair do |system, (origin, distance, mangled_name)|
    puts "Watching for #{system}: #{distance} jumps from #{origin}," \
         " matching as #{mangled_name}"
    result << mangled_name
  end
  result
end

char_names = ARGV.shift.encode(Encoding::UTF_8).split(',')

system_names = []
distance = {}
ARGV.each do |arg|
  if p = arg.index("+")
    raise "Cannot do distance-based intel filtering "\
          "without sqlite + the EVE universe DB" unless has_db
    sys, dist = arg[0...p], arg[p+1..-1].to_i
    distance[sys] = dist
  else
    system_names << arg
  end
end
system_names += systems_by_distance(distance)
system_names.map!{|arg| /\b#{arg}\S*/i}

if system_names.empty?
  raise "no system names given"
end

ping_at_exit = true
Signal.trap('INT') do
  if $currently_panicking
    pid = $currently_panicking
    $currently_panicking = nil
    Process.kill('INT', pid)
  else
    ping_at_exit = false
    puts
    exit
  end
end
at_exit do
  send_notification("exiting") if ping_at_exit
end

files = []
last_alert_sound = 0
intel_log = nil
begin
  files << notifier = INotify::Notifier.new
  notifier_io = notifier.to_io
  game_log_states = []
  char_names.each do |char_name|
    game_filename = find_latest(GAME_LOG_DIR) { |path, date|
      from_this_week(date) && path.end_with?(".txt") &&
        is_log_for(path, char_name)
    }
    puts "Opening #{game_filename} for #{char_name}"
    game_log_states << game_log_state = GameLogState.new(char_name)
    files << listen(notifier, game_filename, nil) do |lines|
      lines.each do |line|
        game_log_state.feed(line)
      end
    end
  end
  loop do
    unless intel_log
      intel_filename = find_open_chatlog(INTEL_LOG_DIR, INTEL_LOG_PREFIX)
      raise "no intel chatlog found" unless intel_filename
      puts "Opening #{intel_filename}"
      intel_log = listen(notifier, intel_filename, "rb:UTF-16LE",
                      proc do intel_log = nil end) do |lines|
        lines.delete_if { |line|
          line_ = line[(line.index('>') or 0)+2..-1]
          !system_names.any? { |sys|
            if sys.match(line_)
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
        unless lines.empty? || game_log_states.all?(&:docked?)
          now = Time.now.to_i
          if now - last_alert_sound > 5
            send_notification("#{INTEL_LOG_PREFIX}: #{lines.join("\n")}")
            last_alert_sound = now
          end
        end
      end
    end
    if select([notifier_io], [], [notifier_io], 5)
      notifier.process
    end
    game_log_states.each(&:idle)
  end
ensure
  files.each do |f| f.close end
  intel_log.close if intel_log
end

