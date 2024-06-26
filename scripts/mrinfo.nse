local nmap = require "nmap"
local packet = require "packet"
local ipOps = require "ipOps"
local stdnse = require "stdnse"
local string = require "string"
local target = require "target"
local table = require "table"


description = [[
Queries targets for multicast routing information.

This works by sending a DVMRP Ask Neighbors 2 request to the target and
listening for DVMRP Neighbors 2 responses that are sent back and which contain
local addresses and the multicast neighbors on each interface of the target. If
no specific target is specified, the request will be sent to the 224.0.0.1 All
Hosts multicast address.

This script is similar somehow to the mrinfo utility included with Windows and
Cisco IOS.
]]

---
-- @args mrinfo.target Host to which the request is sent. If not set, the
-- request will be sent to <code>224.0.0.1</code>.
--
-- @args mrinfo.timeout Time to wait for responses.
-- Defaults to <code>5s</code>.
--
--@usage
-- nmap --script mrinfo
-- nmap --script mrinfo -e eth1
-- nmap --script mrinfo --script-args 'mrinfo.target=172.16.0.4'
--
--@output
-- Pre-scan script results:
-- | mrinfo:
-- |   Source: 224.0.0.1
-- |     Version 12.4
-- |     Local address: 172.16.0.2
-- |       Neighbor: 172.16.0.4
-- |       Neighbor: 172.16.0.3
-- |     Local address: 172.17.0.1
-- |       Neighbor: 172.17.0.2
-- |     Local address: 172.18.0.1
-- |       Neighbor: 172.18.0.2
-- |   Source: 224.0.0.1
-- |     Version 12.4
-- |     Local address: 172.16.0.4
-- |       Neighbor: 172.16.0.3
-- |       Neighbor: 172.16.0.2
-- |     Local address: 172.17.0.2
-- |       Neighbor: 172.17.0.1
-- |   Source: 224.0.0.1
-- |     Version 12.4
-- |     Local address: 172.16.0.3
-- |       Neighbor: 172.16.0.4
-- |       Neighbor: 172.16.0.2
-- |     Local address: 172.18.0.2
-- |       Neighbor: 172.18.0.1
-- |_  Use the newtargets script-arg to add the responses as targets
--


author = "Hani Benhabiles"

license = "Same as Nmap--See https://nmap.org/book/man-legal.html"

categories = {"discovery", "safe", "broadcast"}


prerule = function()
  if nmap.address_family() ~= 'inet' then
    stdnse.verbose1("is IPv4 only.")
    return false
  end
  if not nmap.is_privileged() then
    stdnse.verbose1("not running for lack of privileges.")
    return false
  end
  return true
end

-- Parses a DVMRP Ask Neighbor 2 raw data and returns
-- a structured response.
-- @param data raw data.
local mrinfoParse = function(data)
  local index, address, neighbor
  local response = {}

  -- first byte should be IGMP type == 0x13 (DVMRP)
  if data:byte(1) ~= 0x13 then return end

  -- DVMRP Code
  response.code,
  -- Checksum
  response.checksum,
  -- Capabilities (Skip one reserved byte)
  response.capabilities,
  -- Major and minor version
  response.minver,
  response.majver, index = string.unpack(">B I2 x B B B", data, 2)
  response.addresses = {}
  -- Iterate over target local addresses (interfaces)
  while index < #data do
    if data:byte(index) == 0x00 then break end
    address = {}
    -- Local address
    address.ip,
    -- Link metric
    address.metric,
    -- Threshold
    address.threshold,
    -- Flags
    address.flags,
    -- Number of neighbors
    address.ncount, index = string.unpack(">c4BBBB", data, index)
    address.ip = ipOps.str_to_ip(address.ip)

    address.neighbors = {}
    -- Iterate over neighbors
    for i = 1, address.ncount do
      neighbor, index = string.unpack(">c4", data, index)
      table.insert(address.neighbors, ipOps.str_to_ip(neighbor))
    end
    table.insert(response.addresses, address)
  end
  return response
end

-- Listens for DVMRP Ask Neighbors 2 responses
--@param interface Network interface to listen on.
--@param timeout Time to listen for a response.
--@param responses table to insert responses into.
local mrinfoListen = function(interface, timeout, responses)
  local condvar = nmap.condvar(responses)
  local start = nmap.clock_ms()
  local listener = nmap.new_socket()
  local p, mrinfo_raw, status, l3data, response, _

  -- IGMP packets that are sent to our host
  local filter = 'ip proto 2 and dst host ' .. interface.address
  listener:set_timeout(100)
  listener:pcap_open(interface.device, 1024, true, filter)

  while (nmap.clock_ms() - start) < timeout do
    status, _, _, l3data = listener:pcap_receive()
    if status then
      p = packet.Packet:new(l3data, #l3data)
      mrinfo_raw = string.sub(l3data, p.ip_hl*4 + 1)
      if p then
        -- Check that IGMP Type == DVMRP (0x13) and DVMRP code == Neighbor 2 (0x06)
        if mrinfo_raw:byte(1) == 0x13 and mrinfo_raw:byte(2) == 0x06 then
          response = mrinfoParse(mrinfo_raw)
          if response then
            response.srcip = p.ip_src
            table.insert(responses, response)
          end
        end
      end
    end
  end
  condvar("signal")
end

-- Function that generates a raw DVMRP Ask Neighbors 2 request.
local mrinfoRaw = function()
  local mrinfo_raw = string.pack(">BB I2 I2 BB",
    0x13, -- Type: DVMRP
    0x05, -- Code: Ask Neighbor v2
    0x0000, -- Checksum: Calculated later
    0x000a, -- Reserved
    -- Version == Cisco IOS 12.4
    0x04, -- Minor version: 4
    0x0c) -- Major version: 12

  -- Calculate checksum
  mrinfo_raw = mrinfo_raw:sub(1,2) .. string.pack(">I2", packet.in_cksum(mrinfo_raw)) .. mrinfo_raw:sub(5)

  return mrinfo_raw
end

-- Function that sends a DVMRP query.
--@param interface Network interface to use.
--@param dstip Destination IP to send to.
local mrinfoQuery = function(interface, dstip)
  local mrinfo_packet, sock, eth_hdr
  local srcip = interface.address

  local mrinfo_raw = mrinfoRaw()
  local ip_raw = stdnse.fromhex( "45c00040ed780000400218bc0a00c8750a00c86b") .. mrinfo_raw
  mrinfo_packet = packet.Packet:new(ip_raw, ip_raw:len())
  mrinfo_packet:ip_set_bin_src(ipOps.ip_to_str(srcip))
  mrinfo_packet:ip_set_bin_dst(ipOps.ip_to_str(dstip))
  mrinfo_packet:ip_set_len(ip_raw:len())
  if dstip == "224.0.0.1" then
    -- Doesn't affect results, but we should respect RFC 3171 :)
    mrinfo_packet:ip_set_ttl(1)
  end
  mrinfo_packet:ip_count_checksum()

  sock = nmap.new_dnet()
  if dstip == "224.0.0.1" then
    sock:ethernet_open(interface.device)
    -- Ethernet IPv4 multicast, our ethernet address and packet type IP
    eth_hdr = "\x01\x00\x5e\x00\x00\x01" .. interface.mac .. "\x08\x00"
    sock:ethernet_send(eth_hdr .. mrinfo_packet.buf)
    sock:ethernet_close()
  else
    sock:ip_open()
    sock:ip_send(mrinfo_packet.buf, dstip)
    sock:ip_close()
  end
end

-- Returns the network interface used to send packets to a target host.
--@param target host to which the interface is used.
--@return interface Network interface used for target host.
local getInterface = function(interfaces, target)
  -- First, create dummy UDP connection to get interface
  local sock = nmap.new_socket()
  local status, err = sock:connect(target, "12345", "udp")
  if not status then
    stdnse.verbose1("%s", err)
    return
  end
  local status, address, _, _, _ = sock:get_info()
  if not status then
    stdnse.verbose1("%s", err)
    return
  end
  for _, interface in ipairs(interfaces) do
    if interface.address == address then
      return interface
    end
  end
end

local filter_interfaces = function (if_table)
  if if_table.up == "up" and if_table.address:match("%d+%.%d+%.%d+%.%d+") then
    return if_table
  end
end

action = function()
  local timeout = stdnse.parse_timespec(stdnse.get_script_args(SCRIPT_NAME .. ".timeout"))
  timeout = (timeout or 5) * 1000
  local target = stdnse.get_script_args(SCRIPT_NAME .. ".target") or "224.0.0.1"
  local responses = {}
  local interface, result

  local interfaces = stdnse.get_script_interfaces(filter_interfaces)
  if #interfaces > 1 then
    -- TODO: send on multiple interfaces
    interface = getInterface(interfaces, target)
  elseif #interfaces == 1 then
    interface = interfaces[1]
  end

  if not interface then
    return stdnse.format_output(false, ("Couldn't get interface for %s"):format(target))
  end

  stdnse.debug1("will send to %s via %s interface.", target, interface.shortname)

  -- Thread that listens for responses
  stdnse.new_thread(mrinfoListen, interface, timeout, responses)

  -- Send request after small wait to let Listener start
  stdnse.sleep(0.1)
  mrinfoQuery(interface, target)
  local condvar = nmap.condvar(responses)
  condvar("wait")

  if #responses > 0 then
    local output, ifoutput = {}
    for _, response in pairs(responses) do
      result = {}
      result.name = "Source: " .. response.srcip
      table.insert(result, ("Version %s.%s"):format(response.majver, response.minver))
      for _, address in pairs(response.addresses) do
        ifoutput = {}
        ifoutput.name = "Local address: " .. address.ip
        for _, neighbor in pairs(address.neighbors) do
          if target.ALLOW_NEW_TARGETS then target.add(neighbor) end
          table.insert(ifoutput, "Neighbor: " .. neighbor)
        end
        table.insert(result, ifoutput)
      end
      table.insert(output, result)
    end
    if not target.ALLOW_NEW_TARGETS then
      table.insert(output,"Use the newtargets script-arg to add the results as targets")
    end
    return stdnse.format_output(true, output)
  end
end
