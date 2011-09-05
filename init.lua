----------------------------------------------------------------------
--
-- Copyright (c) 2011 Clement Farabet
--
-- Permission is hereby granted, free of charge, to any person obtaining
-- a copy of this software and associated documentation files (the
-- "Software"), to deal in the Software without restriction, including
-- without limitation the rights to use, copy, modify, merge, publish,
-- distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to
-- the following conditions:
--
-- The above copyright notice and this permission notice shall be
-- included in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
-- NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
-- LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
-- OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
-- WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--
----------------------------------------------------------------------
-- description:
--     parallel - a package that provides a simple mechanism to
--                dispatch Lua scripts as independant processes
--                and communicate via a super raw shared memory
--                buffer
--
-- history:
--     September  2, 2011, 5:42PM - using 0MQ instead of IPC - Scoffier / Farabet
--     August 27, 2011, 6:31PM - beta release - Clement Farabet
--     August 26, 2011, 6:03PM - creation - Clement Farabet
----------------------------------------------------------------------

require 'os'
require 'io'
require 'sys'
require 'torch'
require 'zmq'

local glob = _G
local assignedid
if parallel then 
   assignedid = parallel.id
   assignedip = parallel.ip
   parent = parallel.parent
end
local sys = sys
local zmq = zmq
local type = type
local tostring = tostring
local torch = torch
local error = error
local table = table
local require = require
local os = os
local io = io
local pairs = pairs
local ipairs = ipairs

module 'parallel'
_lib = glob.libparallel
glob.libparallel = nil

--------------------------------------------------------------------------------
-- 0MQ context and options
--------------------------------------------------------------------------------
zmqctx = zmq.init(1)
currentport = 6000

--------------------------------------------------------------------------------
-- configure local IP
--------------------------------------------------------------------------------
autoip = function(interface)
            local interfaces
            if type(interface) == 'table' then
               interfaces = interface
            elseif interface then
               interfaces = {interface}
            end
            if sys.OS == 'linux' then
               interfaces = interfaces or {'eth0','eth1'}
               local ipfound
               for _,interface in ipairs(interfaces) do
                  ipfound = sys.execute("/sbin/ifconfig " .. interface
                                        .. " | grep 'inet addr:'| grep -v '127.0.0.1'"
                                        .. " | cut -d: -f2 | awk '{ print $1}'")
                  if ipfound:find('%d') then
                     ip = ipfound:gsub('%s','')
                     break
                  end
               end
            elseif sys.OS == 'macos' then
               interfaces = interfaces or {'en0','en1'}
               local ipfound
               for _,interface in ipairs(interfaces) do
                  ipfound = sys.execute("/sbin/ifconfig " .. interface
                                        .. " | grep -E 'inet.[0-9]' | grep -v '127.0.0.1'"
                                        .. " | awk '{ print $2}'")
                  if ipfound:find('%d') then
                     ip = ipfound:gsub('%s','')
                     break
                  end
               end
            else
               print('WARNING: unsupported OS')
               return
            end
         end

--------------------------------------------------------------------------------
-- run is a shortcut for fork/exec code on the local machine
--------------------------------------------------------------------------------
run = function(code,...)
         -- (1) fork process
         local child = fork(nil, nil, nil, ...)

         -- (2) exec code
         child:exec(code)
      end

--------------------------------------------------------------------------------
-- fork new idle process
--------------------------------------------------------------------------------
fork = function(rip, protocol, rlua, ...)
          -- (0) remote or local connection
          local lip
          if rip then
             protocol = protocol or 'ssh -Y'
             rlua = rlua or 'lua'
             if ip == '127.0.0.1' then
                print('<parallel.fork> WARNING: local ip is set to localhost, forked'
                      .. ' remote processes will not be able to reach it,'
                      .. ' please set your local ip: parallel.ip = "XX.XX.XX.XX"')
             end
             lip = ip
          else
             lip = '127.0.0.1'
          end

          -- (1) create sockets to communicate with child
          local sockwr = zmqctx:socket(zmq.PUSH)
          local sockrd = zmqctx:socket(zmq.PULL)
          local portwr = currentport
          while not sockwr:bind("tcp://*:" .. portwr) do
             currentport = currentport + 1
             portwr = currentport
          end
          local portrd = currentport
          while not sockrd:bind("tcp://*:" .. portrd) do
             currentport = currentport + 1
             portrd = currentport
          end

          -- (2) generate code for child
          --     this involve setting its id, parent id, and making sure it connects
          --     to its parent
          local str =  "parallel = {} "
          str = str .. "parallel.id = " .. processid .. " "
          str = str .. "parallel.parent = {id = " .. id .. "} "
          str = str .. "require([[parallel]]) "
          str = str .. "parallel.parent.socketrd = parallel.zmqctx:socket(zmq.PULL) "
          str = str .. "parallel.parent.socketrd:connect([[tcp://"..lip..":"..portwr.."]]) "
          str = str .. "parallel.parent.socketwr = parallel.zmqctx:socket(zmq.PUSH) "
          str = str .. "parallel.parent.socketwr:connect([[tcp://"..lip..":"..portrd.."]]) "
          local args = {...}
          str = str .. "parallel.args = {}"
          for i = 1,glob.select('#',...) do
             str = str .. 'table.insert(parallel.args, ' .. tostring(args[i]) .. ') '
          end
          str = str .. "loadstring(parallel.parent:receive())() "

          -- (3) fork a lua process, running the code dumped above
          local pid
          if protocol then
             pid = sys.execute(protocol .. ' ' .. rip ..
                               ' "' .. rlua .. " -e '" .. str .. "' " .. '" &  echo $!')
          else
             pid = sys.execute('lua -e "' .. str .. '" & echo $!')
          end
          pid = pid:gsub('%s','')

          -- (4) register child process for future reference
          local child = {id=processid, unixid=pid, ip=rip, speed=1,
                         socketwr=sockwr, socketrd=sockrd}
          _fill(child)
          children[processid] = child
          nchildren = nchildren + 1

          -- (5) incr counter for next process
          processid = processid + 1
          return child
       end

--------------------------------------------------------------------------------
-- nfork = fork N processes, according to the given configuration
-- the configuration is a table with N entries, each entry being:
-- entry = {NB_PROCESSES, ip='IP_ADDR', protocol='PROTOCOL', lua='REMOTE_LUA_CMD_LINE'}
--------------------------------------------------------------------------------
nfork = function(...)
           local args = {...}
           local config
           if type(args[1]) == 'table' then 
              config = args
              if type(config[1][1]) == 'table' then config = config[1] end
           else 
              config = {args} 
           end
           local forked = {}
           for i,entry in ipairs(config) do
              for k = 1,entry[1] do
                 local child = fork(entry.ip, entry.protocol, entry.lua)
                 table.insert(forked, child)
              end
           end
           _fill(forked)
           return forked
        end

--------------------------------------------------------------------------------
-- sfork = smart fork N processes, according to the current remotes table
-- parallel.addremote() should be called first to configure which machines are
-- available, and how many cores each one has
--------------------------------------------------------------------------------
sfork = function(nb)
           local forked = {}
           if not remotes then
              -- local fork
              table.insert(forked, nfork(nb))
           else
              -- remote fork: distribute processes on all remotes
              while nb ~= 0 do
                 for i,remote in ipairs(remotes) do
                    if remote.cores > 0 or remotes.cores <= 0 then
                       local child = fork(remote.ip, remote.protocol, remote.lua)
                       child.remote = remote
                       child.speed = remote.speed or 1
                       remote.cores = remote.cores - 1
                       remotes.cores = remotes.cores - 1
                       table.insert(forked, child)
                       if remotes.cores < 0 then
                          print('WARNING: forking more processes than cores available')
                       end
                       nb = nb - 1
                       if nb == 0 then break end
                    end
                 end
              end
           end
           _fill(forked)
           return forked
        end

--------------------------------------------------------------------------------
-- exec code in given process
--------------------------------------------------------------------------------
exec = function(process, code)
          local processes = process
          if process.id then processes = {process} end
          -- make sure no process is already running code
          for _,process in pairs(processes) do
             if type(process) == 'table' then
                if process.running then
                   error('<parallel.exec> process already running code, cannot exec again')
                end
                process.running = true
             end
          end
          -- close() after code is executed
          code = code .. '\n parallel.close()'
          -- load all processes with code
          send(processes, code)
       end

--------------------------------------------------------------------------------
-- join = synchronize processes that have yielded, blocking call
--------------------------------------------------------------------------------
join = function(process, msg)
          msg = msg or ''
          if not process.id then 
             -- a list of processes to join
             for _,proc in pairs(process) do
                if type(proc) == 'table' then
                   proc.socketwr:send(msg)
                   proc.socketrd:recv()
                end
             end
          else 
             -- a single process to join
             process.socketwr:send(msg)
             process.socketrd:recv()
          end
       end

--------------------------------------------------------------------------------
-- yield = interupt execution flow to allow parent to join
--------------------------------------------------------------------------------
yield = function()
           local msg = parent.socketrd:recv()
           parent.socketwr:send('!')
           return msg
        end

--------------------------------------------------------------------------------
-- sync = wait on a process, or processes, to terminate
--------------------------------------------------------------------------------
sync = function(process)
          if not process.id then 
             -- a list of processes to sync
             for _,proc in pairs(process) do
                if type(proc) == 'table' then
                   sync(proc)
                end
             end
          else 
             -- a single process to sync
             while true do
                local alive = sys.execute("ps -ef | awk '{if ($2 == " .. 
                                          process.unixid .. ") {print $2}}'"):gsub('%s','')
                if alive == '' then
                   if process.remote and process.remote.cores then
                      process.remote.cores = process.remote.cores + 1
                      remotes.cores = remotes.cores + 1
                   end
                   children[process.id] = nil
                   nchildren = nchildren - 1
                   break
                end
             end
          end
       end

--------------------------------------------------------------------------------
-- transmit data
--------------------------------------------------------------------------------
send = function(process, object)
          if not process.id then 
             -- multiple processes
             local processes = process
             -- a list of processes to send data to
             if not (torch.typename(object) and torch.typename(object):find('torch.*Storage')) then
                -- serialize data once for all transfers
                local f = torch.MemoryFile()
                f:binary()
                f:writeObject(object)
                object = f:storage()
                f:close()
             end
             -- broadcast storage to all processes
             for _,process in pairs(processes) do
                if type(process) == 'table' then
                   object.zmq.send(object, process.socketwr)
                end
             end
          else
             if torch.typename(object) and torch.typename(object):find('torch.*Storage') then
                -- raw transfer ot storage
                object.zmq.send(object, process.socketwr)
             else
                -- serialize data first
                local f = torch.MemoryFile()
                f:binary()
                f:writeObject(object)
                local s = f:storage()
                -- then transmit raw storage
                send(process, s)
                f:close()
             end
          end
       end

--------------------------------------------------------------------------------
-- receive data
--------------------------------------------------------------------------------
receive = function(process, object)
             if not process.id then 
                -- receive all objects
                if object and object[1] and torch.typename(object[1]) and torch.typename(object[1]):find('torch.*Storage') then
                   -- user objects are storages, just fill them
                   local objects = object
                   for i,proc in pairs(process) do
                      if type(proc) == 'table' then
                         object[i].zmq.recv(object[i], proc.socketrd)
                      end
                   end
                else
                   -- receive raw storages
                   local storages = {}
                   for i,proc in pairs(process) do
                      if type(proc) == 'table' then
                         storages[i] = torch.CharStorage()
                         storages[i].zmq.recv(storages[i], proc.socketrd)
                      end
                   end
                   -- then un-serialize data objects
                   object = object or {}
                   for i,proc in pairs(process) do
                      if type(proc) == 'table' then
                         local f = torch.MemoryFile(storages[i])
                         f:binary()
                         object[i] = f:readObject()
                         f:close()
                      end
                   end
                end
             else
                if object and torch.typename(object) and torch.typename(object):find('torch.*Storage') then
                   -- raw receive of storage
                   object.zmq.recv(object, process.socketrd)
                else
                   -- first receive raw storage
                   local s = torch.CharStorage()
                   receive(process, s)
                   -- then un-serialize data object
                   local f = torch.MemoryFile(s)
                   f:binary()
                   object = f:readObject()
                   f:close()
                end
             end
             return object
          end

--------------------------------------------------------------------------------
-- close = clean up sockets
--------------------------------------------------------------------------------
close = function()
           print('closing session')
           if parent.id ~= -1 then
              os.execute("sleep 1")
           end
           for _,process in pairs(children) do
              -- this is a bit brutal, but at least ensures that
              -- all forked children are *really* killed
              if type(process) == 'table' then
                 os.execute('kill -9 ' .. process.unixid)
              end
           end
           if remotes then
              os.execute("sleep 1")
              for _,remote in ipairs(remotes) do
                 -- second brutal thing: check for remote processes that
                 -- might have become orphans, and kill them
                 local prot = remote.protocol or 'ssh'
                 local orphans = sys.execute(prot .. " " .. remote.ip .. " " ..
                                             "ps -ef | grep 'lua -e parallel' "  ..
                                             "| awk '{if ($3 == 1) {print $2}}'")
                 local kill = 'kill -9 '
                 local pids = ''
                 for orphan in orphans:gfind('%d+') do
                    pids = pids .. orphan .. ' '
                 end
                 if pids ~= '' then
                    os.execute(prot .. ' ' .. remote.ip .. ' "' .. kill .. pids .. '"')
                 end
              end
           end
        end

--------------------------------------------------------------------------------
-- all processes should use this print method
--------------------------------------------------------------------------------
local _print = glob.print
print = function(...)
           _print('<parallel#' .. glob.string.format('%03d',id) .. '>', ...)
        end

--------------------------------------------------------------------------------
-- add remote machine
-- the table given is a table with N entries, each entry being:
-- entry = {ip='IP_ADDR', protocol='PROTOCOL', lua='REMOTE_LUA_CMD_LINE', cores='NB_CORES'}
--------------------------------------------------------------------------------
addremote = function(...)
               local args = {...}
               local config
               if type(args[1]) == 'table' then 
                  config = args
                  if type(config[1][1]) == 'table' then config = config[1] end
               else 
                  config = {args} 
               end
               remotes = remotes or {cores=0}
               for i,entry in ipairs(config) do
                  glob.table.insert(remotes, entry)
                  remotes.cores = remotes.cores + entry.cores
               end
            end

--------------------------------------------------------------------------------
-- calibrate remote machines: this function executes as many processes a
-- cores declared for each machine, and assigns a speed coefficient to each
-- machine. Processes forked on these machines will inherit from this 
-- coefficient.
-- coefs: 1.0 is the fastest machine
--        0.5 means that the machine is 2x slower than the faster
-- so, typically, if a process has coef 0.5, you want to give it twice as less
-- stuff to process than the process that has coef 1.0.
--------------------------------------------------------------------------------
calibrate = function()
               -- only calibrate if 'remotes' have been declared
               if not remotes then
                  error('<parallel.calibrate> calibration can only be done after addremote() is called')
                  return
               end
               print('calibrating remote machines')
               -- calibration code:
               local calib = [[
                     require 'torch'
                     require 'sys'
                     s = torch.Tensor(10000):fill(1)
                     d = torch.Tensor(10000):fill(0)
                     parallel.yield()
                     sys.tic()
                     for i = 1,100000 do
                        d:add(13,s)
                     end
                     time = sys.toc()
                     parallel.parent:send(time)
               ]]
               -- run calibration on as many cores as available
               local forked = sfork(remotes.cores)
               forked:exec(calib)
               forked:join()
               local times = forked:receive()
               forked:sync()
               -- normalize times
               local max = 0
               for i,time in pairs(times) do if time > max then max = time end end
               for i,time in pairs(times) do times[i] = time/max end
               -- store coefs in each remote
               for _,remote in ipairs(remotes) do
                  for i,time in pairs(times) do
                     if forked[i].ip == remote.ip then
                        remote.speed = glob.math.floor( time*10 + 0.5 ) / 10
                        break
                     end
                  end
               end
            end

--------------------------------------------------------------------------------
-- create new process table, with methods
--------------------------------------------------------------------------------
_fill = function(process)
           process.join = join
           process.sync = sync
           process.send = send
           process.receive = receive
           process.exec = exec
        end

--------------------------------------------------------------------------------
-- reset = forget all children, go back to initial state
-- TODO: this is the right place to properly terminate children
--------------------------------------------------------------------------------
reset = function()
           id = assignedid or 0
           ip = assignedip or "127.0.0.1"
           parent = parent or {id = -1}
           children = {}
           processid = 1
           if parent.id ~= -1 then
              parent.receive = receive
              parent.send = send
           end
           _fill(children)
           nchildren = 0
           autoip()
        end
reset()
