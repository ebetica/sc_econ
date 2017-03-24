require 'torch'
torch.setdefaulttensortype('torch.FloatTensor')
require 'sys'
local lapp = require 'pl.lapp'
local args = lapp [[
Baselines for Starcraft
-t,--hostname       (default "")    Give hostname / ip pointing to VM
-p,--port           (default 11111) Port for torchcraft.
-d,--debug          (default 0)     can take values 0, 1, 2 (from no output to most verbose)
]]

local skip_frames = 7
local port = args.port
local hostname = args.hostname or ""
print("hostname:", hostname)
print("port:", port)

local DEBUG = args.debug
local tc = require 'torchcraft'
tc.DEBUG = DEBUG
-- Enables a battle ended flag, for when one side loses all units
tc.micro_battles = MICRO_MODE
local utils = require 'torchcraft.utils'

local function get_closest(position, unitsTable)
  local min_d = 1E30
  local closest_uid = nil
  for uid, ut in pairs(unitsTable) do
    local tmp_d = utils.distance(position, ut['position'])
    if tmp_d < min_d then
      min_d = tmp_d
      closest_uid = uid
    end
  end
  return closest_uid
end


total_battles = 0
while total_battles < 40 do

  print("")
  print("CTRL-C to stop")
  print("")

  local frames_in_battle = 1
  local nloop = 1

  tc:init(hostname, port)
  local update = tc:connect(port)
  if DEBUG > 1 then
    print('Received init: ', update)
  end
  assert(tc.state.replay == false)

  -- first message to BWAPI's side is setting up variables
  local setup = {
    tc.command(tc.set_speed, 0), tc.command(tc.set_gui, 1),
    tc.command(tc.set_cmd_optim, 1),
  }
  tc:send({table.concat(setup, ':')})

  local built_barracks = 0
  local building_supply = false
  local battle_ended = false

  local nunits = nil
  local producing = false
  while not tc.state.game_ended do
    update = tc:receive()
    if DEBUG > 1 then
      print('Received update: ', update)
    end

    nloop = nloop + 1
    local actions = {}
    if tc.state.game_ended then
      break
    elseif battle_ended then
      if DEBUG > 0 then
        print("BATTLE ENDED")
      end
      total_battles = total_battles + 1
      print("Scenario ended with resources: ")
      print(tc.state.resources_myself)
      actions = {tc.command(tc.quit)}
    else
      if tc.state.resources_myself.used_psi ~= tc.state.resources_myself.total_psi then
        building_supply = false
      end
      if tc.state.battle_frame_count % skip_frames == 0 then
        local num = 0
        local scvs = tc:filter_type(tc.state.units_myself, {tc.unittypes.Terran_SCV})
        for _ in pairs(scvs) do num = num + 1 end
        if nunits ~= num then
          producing = false
        end
        nunits = num
        for uid, ut in pairs(tc.state.units_myself) do
          if tc:isbuilding(ut.type) then -- produce scv only if not producing
            if ut.type == tc.unittypes.Terran_Command_Center
              and not producing and tc.state.resources_myself.ore >= 50 then
              table.insert(actions,
                tc.command(tc.command_unit, uid, tc.cmd.Train, 0, 0, 0,
                  tc.unittypes.Terran_SCV))
                -- Target, x, y are all 0,
                -- to train a unit you must input into "extra" field
                producing = true
            end
          elseif tc:isworker(ut.type) then
            if tc.state.resources_myself.ore >= 150
              and tc.state.frame_from_bwapi - built_barracks > 240 then
              built_barracks = tc.state.frame_from_bwapi
                local _, pos = next(tc:filter_type(
                  tc.state.units_myself,
                  {tc.unittypes.Terran_Command_Center}))
              if pos ~= nil then pos = pos.position end
              if pos ~= nil and not utils.is_in(ut.order,
                tc.command2order[tc.unitcommandtypes.Build])
                and not utils.is_in(ut.order,
                tc.command2order[tc.unitcommandtypes.Right_Click_Position]) then
                table.insert(actions,
                  tc.command(tc.command_unit, uid,
                  tc.cmd.Build, -1,
                  pos[1], pos[2] - 45, tc.unittypes.Terran_Barracks))
              end
            elseif tc.state.resources_myself.ore >= 105 and
              tc.state.resources_myself.used_psi >= tc.state.resources_myself.total_psi - 1
              and not building_supply then
                local built_supply = 0
                local building = false
                local sups = tc:filter_type(tc.state.units_myself,
                                            {tc.unittypes.Terran_Supply_Depot})
                for _, v in pairs(sups) do
                  built_supply = built_supply + 1
                end
                -- Reset on second supply
                if built_supply == 2 then battle_ended = true end
                local _, pos = next(tc:filter_type(
                  tc.state.units_myself,
                  {tc.unittypes.Terran_Command_Center}))
                if pos ~= nil then pos = pos.position end
                if pos ~= nil and not utils.is_in(ut.order,
                  tc.command2order[tc.unitcommandtypes.Build])
                  and not utils.is_in(ut.order,
                  tc.command2order[tc.unitcommandtypes.Right_Click_Position]) then
                  table.insert(actions,
                    tc.command(tc.command_unit, uid,
                    tc.cmd.Build, -1, pos[1], pos[2] + 8 + 8 * built_supply,
                    tc.unittypes.Terran_Supply_Depot))
                end
                building_supply = true
            else -- tests gathering
              if not utils.is_in(ut.order, tc.command2order[tc.unitcommandtypes.Gather])
                and not utils.is_in(ut.order, tc.command2order[tc.unitcommandtypes.Build])
                and not utils.is_in(ut.order, tc.command2order[tc.unitcommandtypes.Right_Click_Position]) then
                -- avoid spamming the order is the unit is already
                -- following the right order or building!
                local target = get_closest(ut.position,
                  tc:filter_type(tc.state.units_neutral,
                  {tc.unittypes.Resource_Mineral_Field,
                  tc.unittypes.Resource_Mineral_Field_Type_2,
                  tc.unittypes.Resource_Mineral_Field_Type_3}))
                if target ~= nil then
                  table.insert(actions,
                  tc.command(tc.command_unit_protected, uid,
                  tc.cmd.Right_Click_Unit, target))
                end
              end
            end
          end
        end
        if frames_in_battle > 2*60*24 then -- quit after ~ 2 hours
          actions = {tc.command(tc.quit)}
          nrestarts = nrestarts + 1
        end
      end
    end

    if DEBUG > 1 then
      print("")
      print("Sending actions:")
      print(actions)
    end
    tc:send({table.concat(actions, ':')})
  end
  tc:close()
  sys.sleep(0.5)
  collectgarbage()
  collectgarbage()
end
print("")
