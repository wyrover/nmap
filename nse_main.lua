-- Arguments when this file (function) is called, accessible via ...
--   [1] The NSE C library. This is saved in the local variable cnse for
--       access throughout the file.
--   [2] The list of categories/files/directories passed via --script.
-- The actual arguments passed to the anonymous main function:
--   [1] The list of hosts we run against.
--
-- A few notes about the safety of the engine, that is, the ability for
-- a script developer to crash or otherwise stall NSE. The purpose of noting
-- these attack vectors is more to show the difficulty in accidently
-- breaking the system than to indicate a user may wish to break the
-- system through these means.
--  - A script writer can use the undocumented Lua function newproxy
--    to inject __gc code that could run (and error) at any location.
--  - A script writer can use the debug library to break out of
--    the "sandbox" we give it. This is made a little more difficult by
--    our use of locals to all Lua functions we use and the exclusion
--    of the main thread and subsequent user threads.
--  - A simple while true do end loop can stall the system. This can be
--    avoided by debug hooks to yield the thread at periodic intervals
--    (and perhaps kill the thread) but a C function like string.find and
--    a malicious pattern can stall the system from C just as easily.
--  - The garbage collector function is available to users and they may
--    cause the system to stall through improper use.
--  - Of course the os and io library can cause the system to also break.

local NAME = "NSE";

local _R = debug.getregistry(); -- The registry
local _G = _G;

local assert = assert;
local collectgarbage = collectgarbage;
local error = error;
local getfenv = getfenv;
local ipairs = ipairs;
local loadfile = loadfile;
local loadstring = loadstring;
local next = next;
local pairs = pairs;
local pcall = pcall;
local rawget = rawget;
local select = select;
local setfenv = setfenv;
local setmetatable = setmetatable;
local tonumber = tonumber;
local tostring = tostring;
local type = type;
local unpack = unpack;

local create = coroutine.create;
local resume = coroutine.resume;
local running = coroutine.running;
local status = coroutine.status;
local yield = coroutine.yield;

local traceback = debug.traceback;

local write = io.write;

local ceil = math.ceil;

local byte = string.byte;
local format = string.format;
local find = string.find;
local gsub = string.gsub;
local lower = string.lower;
local match = string.match;

local insert = table.insert;
local remove = table.remove;
local sort = table.sort;

local nmap = require "nmap";

local cnse, rules = ...; -- The NSE C library and Script Rules

do -- Append the nselib directory to the Lua search path
  local t, path = assert(cnse.fetchfile_absolute("nselib/"));
  assert(t == "directory", "could not locate nselib directory!");
  package.path = package.path..";"..path.."?.lua";
end

-- Some local helper functions --

local log_write, verbosity, debugging =
    nmap.log_write, nmap.verbosity, nmap.debugging;

local function print_verbose (level, fmt, ...)
  if verbosity() >= assert(tonumber(level)) or debugging() > 0 then
    log_write("stdout", format(fmt, ...));
  end
end

local function print_debug (level, fmt, ...)
  if debugging() >= assert(tonumber(level)) then
    log_write("stdout", format(fmt, ...));
  end
end

local function log_error (fmt, ...)
  log_write("stderr", format(fmt, ...));
end

local function table_size (t)
  local n = 0; for _ in pairs(t) do n = n + 1; end return n;
end

-- recursively copy a table, for host/port tables
-- not very rigorous, but it doesn't need to be
local function tcopy (t)
  local tc = {};
  for k,v in pairs(t) do
    if type(v) == "table" then
      tc[k] = tcopy(v);
    else
      tc[k] = v;
    end
  end
  return tc;
end

local Script = {}; -- The Script Class, its constructor is Script.new.
local Thread = {}; -- The Thread Class, its constructor is Script:new_thread.
do
  -- Thread:d()
  -- Outputs debug information at level 1 or higher.
  -- Changes "%THREAD" with an appropriate identifier for the debug level
  function Thread:d (fmt, ...)
    if debugging() > 1 then
      print_debug(1, gsub(fmt, "%%THREAD", self.info), ...);
    else
      print_debug(1, gsub(fmt, "%%THREAD", self.short_basename), ...);
    end
  end

  -- thread = Script:new_thread(rule, ...)
  -- Creates a new thread for the script Script.
  -- Arguments:
  --   rule  The rule argument the rule, hostrule or portrule, tested.
  --   ...   The arguments passed to the rule function (host[, port]).
  -- Returns:
  --   thread  The thread (class) is returned, or nil.
  function Script:new_thread (rule, ...)
    assert(rule == "hostrule" or rule == "portrule");
    if not self[rule] then return nil end -- No rule for this script?
    local file_closure = self.file_closure;
    local env = setmetatable({
        runlevel = 1,
        filename = self.filename,
      }, {__index = _G});
    setfenv(file_closure, env);
    local function main (...)
      file_closure(); -- loads script globals
      return env.action(yield(env[rule](...)));
    end
    setfenv(main, env);
    -- This thread allows us to load the script's globals in the
    -- same Lua thread the action and rule functions will execute in.
    local co = create(main);
    local s, rule_return = resume(co, ...);
    if s and rule_return then
      local thread = setmetatable({
        co = co,
        env = env,
        runlevel = ceil(tonumber(rawget(env, "runlevel")) or 1),
        identifier = tostring(co),
        info = format("'%s' (%s)", self.short_basename, tostring(co));
        type = rule == "hostrule" and "host" or "port",
      }, {
        __metatable = Thread,
        __index = function (thread, k) return Thread[k] or self[k] end
      }); -- Access to the parent Script
      thread.parent = thread; -- itself
      return thread;
    elseif not s then
      print_debug(1, "a thread for %s failed to load:\n%s\n", self.filename,
          traceback(co, tostring(rule_return)));
    end
    return nil;
  end

  local required_fields = {
    description = "string",
    action = "function",
    categories = "table",
  };
  -- script = Script.new(filename)
  -- Creates a new Script Class for the script.
  -- Arguments:
  --   filename  The filename (path) of the script to load.
  -- Returns:
  --   script  The script (class) created.
  function Script.new (filename)
    assert(type(filename) == "string", "string expected");
    if not find(filename, "%.nse$") then
      log_error("Warning: Loading '"..filename..
          "' - the recommended file extension is '.nse'.");
    end
    local file_closure = assert(loadfile(filename));
    -- Give the closure its own environment, with global access
    local env = setmetatable({}, {__index = _G});
    setfenv(file_closure, env);
    local co = create(file_closure); -- Create a garbage thread
    assert(resume(co)); -- Get the globals it loads in env
    -- Check that all the required fields were set
    for f, t in pairs(required_fields) do
      local field = rawget(env, f);
      if field == nil then
        error(filename.." is missing required field: '"..f.."'");
      elseif type(field) ~= t then
        error(filename.." field '"..f.."' is of improper type '"..
            type(field).."', expected type '"..t.."'");
      end
    end
    -- Check one of two required rule functions exists
    local hostrule, portrule = rawget(env, "hostrule"), rawget(env, "portrule");
    assert(type(hostrule) == "function" or type(portrule) == "function",
        filename.." is missing a required function: 'hostrule' or 'portrule'");
    -- Assert that categories is an array of strings
    for i, category in ipairs(rawget(env, "categories")) do
      assert(type(category) == "string", 
        filename.." has non-string entries in the 'categories' array");
    end
    -- Return the script
    return setmetatable({
      filename = filename,
      basename = match(filename, "[/\\]([^/\\]-)$") or filename,
      short_basename = match(filename, "[/\\]([^/\\]-)%.nse$") or
                       match(filename, "[/\\]([^/\\]-)%.[^.]*$") or
                       filename,
      id = match(filename, "^.-[/\\]([^\\/]-)%.nse$") or filename,
      file_closure = file_closure,
      hostrule = type(hostrule) == "function" and hostrule or nil,
      portrule = type(portrule) == "function" and portrule or nil,
      args = {n = 0};
      categories = rawget(env, "categories"),
      author = rawget(env, "author"),
      license = rawget(env, "license"),
      runlevel = ceil(tonumber(rawget(env, "runlevel")) or 1),
      threads = {},
    }, {__index = Script, __metatable = Script});
  end
end

-- check_rules(rules)
-- Ensures reserved rules are not explicitly specified.
-- Adds the "default" category if no rules were specified.
-- Adds reserved rules that were internally specified (--sV for "version").
--
-- Arguments:
--   rules  The array of rules to check.
local function check_rules (rules)
  local reserved = {
    version = not not cnse.scriptversion,
  };
  for i, rule in ipairs(rules) do
    if reserved[lower(rule)] ~= nil then
      error("explicitly specifying rule '"..rule.."' is prohibited");
    end
  end
  if cnse.default and #rules == 0 then rules[1] = "default"; end
  for rule, option in pairs(reserved) do
    if option then rules[#rules+1] = rule; end
  end
end

-- chosen_scripts = get_chosen_scripts(rules)
-- Loads all the scripts for the given rules using the Script Database.
-- Arguments:
--   rules  The array of rules to use for loading scripts.
-- Returns:
--   chosen_scripts  The array of scripts loaded for the given rules. 
local function get_chosen_scripts (rules)
  check_rules(rules);

  local script_dbpath = cnse.script_dbpath;
  local t, path = cnse.fetchfile_absolute(script_dbpath);
  if not t then
    print_verbose(1, "Creating non-existent script database.");
    assert(cnse.updatedb(), "could not update script database!");
    t, path = assert(cnse.fetchfile_absolute(script_dbpath));
  end
  local db_closure = assert(loadfile(path));

  local chosen_scripts, entry_rules, files_loaded = {}, {}, {};

  -- Initialize entry_rules with the list of rules provided by the user.
  -- Each element of entry_rules may refer to another canonical element.
  -- Here the lower-case rule points to the potentially mixed-case rule
  -- provided by the user.
  for i, rule in ipairs(rules) do
    entry_rules[lower(rule)] = rule;
    entry_rules[rule] = false;
  end

  -- Start by loading scripts by category. This function is run on each
  -- Entry in script.db.
  local function entry (script_entry)
    local category, filename = script_entry.category, script_entry.filename;
    assert(type(category) == "string" and type(filename) == "string");

    -- Don't load a file more than once.
    if files_loaded[filename] then return end

    -- Do we have a rule for this category (or an "all" rule)?
    if entry_rules[category] ~= nil or
        entry_rules.all ~= nil and category ~= "version" then
      local index = entry_rules[category] ~= nil and category or "all";
      local mark = entry_rules[index];
      -- mark may point to the actual mixed case category passed via command
      -- line
      if type(mark) == "boolean" then
        entry_rules[index] = true;
      else
        entry_rules[mark] = true;
      end
      local t, path = cnse.fetchfile_absolute(filename);
      assert(t == "file", filename.." is not a file!");
      chosen_scripts[#chosen_scripts+1] = Script.new(path);
      files_loaded[filename] = true;
    end
  end

  setfenv(db_closure, {Entry = entry});
  db_closure(); -- Load the scripts

  -- Now load any scripts listed by name rather than by category.
  for rule, loaded in pairs(entry_rules) do
    if not loaded then -- attempt to load the file/directory
      local t, path = cnse.fetchfile_absolute(rule);
      if t == nil then -- perhaps omitted the extension?
        t, path = cnse.fetchfile_absolute(rule..".nse");
      end
      if t == nil then
        error("No such category, filename or directory: '"..rule.."'");
      elseif t == "file" and not files_loaded[path] then
        chosen_scripts[#chosen_scripts+1] = Script.new(path);
        files_loaded[path] = true;
      elseif t == "directory" then
        for i, file in ipairs(cnse.dump_dir(path)) do
          if not files_loaded[file] then
            chosen_scripts[#chosen_scripts+1] = Script.new(file);
            files_loaded[file] = true;
          end
        end
      end
    end
  end
  return chosen_scripts;
end

-- run(threads)
-- The main loop function for NSE. It handles running all the script threads.
-- Arguments:
--   threads  An array of threads (a runlevel) to run.
local function run (threads)
  -- running scripts may be resumed at any time. waiting scripts are
  -- yielded until Nsock wakes them. After being awakened with
  -- nse_restore, waiting threads become pending and later are moved all
  -- at once back to running.
  local running, waiting, pending = {}, {}, {}
  -- hosts maps a host to a list of threads for that host.
  local hosts, total = {}, 0
  local current
  local progress = cnse.scan_progress_meter(NAME);

  print_debug(1, "NSE Script Threads (%d) running:", #threads);
  while #threads > 0 do
    local thread = remove(threads);
    thread:d("Starting %THREAD against %s.", thread.host.ip)
    running[thread.co], total = thread, total + 1;
    hosts[thread.host] = hosts[thread.host] or {};
    hosts[thread.host][thread.co] = true;
  end

  -- This WAITING_TO_RUNNING function is called by nse_restore in
  -- nse_main.cc.
  _R.WAITING_TO_RUNNING = function (co, ...)
    if waiting[co] then -- ignore a thread not waiting
      pending[co], waiting[co] = waiting[co], nil;
      pending[co].args = {n = select("#", ...), ...};
    end
  end

  -- Loop while any thread is running or waiting.
  while next(running) or next(waiting) do
    local nr, nw = table_size(running), table_size(waiting);
    cnse.nsock_loop(50); -- Allow nsock to perform any pending callbacks
    if cnse.key_was_pressed() then
      print_verbose(1, "Active NSE Script Threads: %d (%d waiting)\n",
          nr+nw, nw);
      progress("printStats", 1-(nr+nw)/total);
    elseif progress "mayBePrinted" then
      if verbosity() > 1 or debugging() > 0 then
        progress("printStats", 1-(nr+nw)/total);
      else
        progress("printStatsIfNecessary", 1-(nr+nw)/total);
      end
    end

    -- Checked for timed-out hosts.
    for co, thread in pairs(waiting) do
      if cnse.timedOut(thread.host) then
        waiting[co] = nil;
        thread:d("%THREAD target timed out");
      end
    end

    for co, thread in pairs(running) do
      current, running[co] = thread, nil;
      cnse.startTimeOutClock(thread.host);

      local s, result = resume(co, unpack(thread.args, 1, thread.args.n));
      if not s then -- script error...
        hosts[thread.host][co] = nil;
        thread:d("%THREAD threw an error!\n%s\n",
            traceback(co, tostring(result)));
      elseif status(co) == "suspended" then
        waiting[co] = thread;
      elseif status(co) == "dead" then
        hosts[thread.host][co] = nil;
        if type(result) == "string" then
          -- Escape any character outside the range 32-126 except for tab,
          -- carriage return, and line feed. This makes the string safe for
          -- screen display as well as XML (see section 2.2 of the XML spec).
          result = gsub(result, "[^\t\r\n\032-\126]", function(a)
            return format("\\x%02X", byte(a));
          end);
          if thread.type == "host" then
            cnse.host_set_output(thread.host, thread.id, result);
          else
            cnse.port_set_output(thread.host, thread.port, thread.id, result);
          end
        end
        thread:d("Finished %THREAD against %s", thread.host.ip);
      end

      -- Any more threads running for this host?
      if not next(hosts[thread.host]) then
        cnse.stopTimeOutClock(thread.host);
      end
    end

    -- Move pending threads back to running.
    for co, thread in pairs(pending) do
      pending[co], running[co] = nil, thread;
    end

    collectgarbage "collect"; -- important for collecting used sockets & proxies
  end

  progress "endTask";
end

do -- Load script arguments
  local args = gsub((cnse.scriptargs or ""), "=([%w_]+)", "=\"%1\"");
  local argsf, err = loadstring("return {"..args.."}", "Script Arguments");
  if not argsf then
    error("failed to parse --script-args:\n"..args.."\n"..err);
  else
    nmap.registry.args = argsf();
  end
end

-- Load all user chosen scripts
local chosen_scripts = get_chosen_scripts(rules);
print_verbose(1, "Loaded %d scripts for scanning.", #chosen_scripts);
for i, script in ipairs(chosen_scripts) do
  print_debug(2, "Loaded '%s'.", script.basename);
end

-- main(hosts)
-- This is the main function we return to NSE (on the C side) which actually
-- runs a scan against an array of hosts. nse_main.cc gets this function
-- by calling loadfile on nse_main.lua.
-- Arguments:
--   hosts  An array of hosts to scan.
return function (hosts)
  if #hosts > 1 then
    print_verbose(1, "Script scanning %d hosts.", #hosts);
  elseif #hosts == 1 then
    print_verbose(1, "Script scanning %s.", hosts[1].ip);
  end

  -- Set up the runlevels.
  local threads, runlevels = {}, {};
  for j, host in ipairs(hosts) do
    -- Check hostrules for this host.
    for i, script in ipairs(chosen_scripts) do
      local thread = script:new_thread("hostrule", tcopy(host));
      if thread then
        local runlevel = thread.runlevel;
        if threads[runlevel] == nil then insert(runlevels, runlevel); end
        threads[runlevel] = threads[runlevel] or {};
        insert(threads[runlevel], thread);
        thread.args, thread.host = {n = 1, tcopy(host)}, host;
      end
    end
    -- Check portrules for this host.
    for port in cnse.ports(host) do
      for i, script in ipairs(chosen_scripts) do
        local thread = script:new_thread("portrule", tcopy(host),
            tcopy(port));
        if thread then
          local runlevel = thread.runlevel;
          if threads[runlevel] == nil then insert(runlevels, runlevel); end
          threads[runlevel] = threads[runlevel] or {};
          insert(threads[runlevel], thread);
          thread.args, thread.host, thread.port =
              {n = 2, tcopy(host), tcopy(port)}, host, port;
        end
      end
    end
  end

  sort(runlevels);
  for i, runlevel in ipairs(runlevels) do
    print_verbose(1, "Starting runlevel %s scan", tostring(runlevel));
    run(threads[runlevel]);
  end

  collectgarbage "collect";
  print_verbose(1, "Script Scanning completed.");
end