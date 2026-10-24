----------------------------------------------------------------
-- StockPiler Adapters/TradeSkillCaps - live cult/apo skill levels
-- Prefer GetTradeSkillLevel / TradeSkillLevels (stock Abilities + Cultivation).
-- Player.tradeSkills often empties mid-session; sticky holds through unknown
-- empties and through explicit-0 blips on GetCultSkill/GetApoSkill.
-- TRADE_SKILL_UPDATED with an explicit 0 is a real unlearn and clears sticky.
----------------------------------------------------------------

StockPiler = StockPiler or {}
StockPiler.TradeSkillCaps = StockPiler.TradeSkillCaps or {}
local Caps = StockPiler.TradeSkillCaps

Caps._skillsReady = Caps._skillsReady == true
Caps._lastCult = tonumber(Caps._lastCult) or 0
Caps._lastApo = tonumber(Caps._lastApo) or 0
-- After LOADING_END, next TRADE_SKILL_UPDATED may legitimately report 0 (new char).
Caps._pendingLoadRefresh = Caps._pendingLoadRefresh == true
Caps._persistedHydrated = Caps._persistedHydrated == true

local function SkillId(name, fallback)
    if GameData and GameData.TradeSkills and GameData.TradeSkills[name] then
        return GameData.TradeSkills[name]
    end
    return fallback
end

--- Returns level, explicit.
--- explicit=true: stock SoT reported a number (including 0 = unlearned).
--- explicit=false: sources missing/empty - keep sticky (combat/scenario blip).
local function ReadLevel(skillId)
    skillId = tonumber(skillId) or 0
    if skillId <= 0 then
        return 0, false
    end
    -- Stock CultivationWindow / AbilitiesWindow / tooltips use these first.
    if type(GetTradeSkillLevel) == "function" then
        local ok, level = pcall(GetTradeSkillLevel, skillId)
        if ok == true and level ~= nil then
            return tonumber(level) or 0, true
        end
    end
    if GameData and type(GameData.TradeSkillLevels) == "table" then
        local level = GameData.TradeSkillLevels[skillId]
        if level ~= nil then
            return tonumber(level) or 0, true
        end
    end
    -- Player.tradeSkills is flaky (empty mid-combat). Only trust a positive
    -- reading; treat missing/0 here as unknown so sticky can cover blips.
    if GameData and GameData.Player and type(GameData.Player.tradeSkills) == "table" then
        local row = GameData.Player.tradeSkills[skillId]
        if type(row) == "table" then
            local level = tonumber(row.level) or 0
            if level > 0 then
                return level, true
            end
            return 0, false
        end
        if row ~= nil then
            local level = tonumber(row) or 0
            if level > 0 then
                return level, true
            end
            return 0, false
        end
    end
    if GameData and type(GameData.TradeSkillData) == "table" then
        local row = GameData.TradeSkillData[skillId]
        if type(row) == "table" then
            local level = tonumber(row.level) or tonumber(row.SkillLevel) or 0
            if level > 0 then
                return level, true
            end
            if row.level ~= nil or row.SkillLevel ~= nil then
                return 0, true
            end
            return 0, false
        end
        if row ~= nil then
            local level = tonumber(row) or 0
            return level, true
        end
    end
    return 0, false
end

local function CharBucket(create)
    if StockPiler.Util and StockPiler.Util.CharacterRow then
        return StockPiler.Util.CharacterRow(create == true)
    end
    return nil
end

--- Once per session: seed sticky from last known character skills (survives /reload
--- before the first non-empty TRADE_SKILL_UPDATED).
local function HydrateStickyFromPersist()
    if Caps._persistedHydrated == true then
        return
    end
    local row = CharBucket(false)
    if type(row) ~= "table" then
        -- Latch only after the character row exists. An early call used to
        -- skip hydration for the rest of the session (ADP-3).
        return
    end
    Caps._persistedHydrated = true
    local pc = tonumber(row.lastCultSkill) or 0
    local pa = tonumber(row.lastApoSkill) or 0
    if (tonumber(Caps._lastCult) or 0) <= 0 and pc > 0 then
        Caps._lastCult = pc
    end
    if (tonumber(Caps._lastApo) or 0) <= 0 and pa > 0 then
        Caps._lastApo = pa
    end
end

local function PersistSticky()
    local cult = tonumber(Caps._lastCult) or 0
    local apo = tonumber(Caps._lastApo) or 0
    local row = CharBucket(true)
    if type(row) ~= "table" then
        return
    end
    -- Always write both so unlearn clears a previous persisted level.
    row.lastCultSkill = cult
    row.lastApoSkill = apo
end

--- live + explicit from ReadLevel.
--- Hot paths keep sticky on explicit 0: TradeSkillLevels can blip to 0 in
--- combat/scenario (0.3.238-0.3.240). Real unlearn is OnTradeSkillPulse.
local function StickLevel(live, explicit, last)
    live = tonumber(live) or 0
    last = tonumber(last) or 0
    if explicit == true and live > 0 then
        return live, live
    end
    if live > 0 then
        return live, live
    end
    -- Transient empty or explicit-0 blip: keep last known.
    if last > 0 then
        return last, last
    end
    return 0, 0
end

function Caps.Refresh()
    if Caps.GetCultSkill() > 0 or Caps.GetApoSkill() > 0 then
        Caps._skillsReady = true
    end
end

function Caps.CultivationId()
    return SkillId("CULTIVATION", 3)
end

function Caps.ApothecaryId()
    return SkillId("APOTHECARY", 4)
end

--- Abilities-window trade skill icon id (GetTradeskillIcon). 0 if unavailable.
function Caps.GetTradeSkillIcon(skillId)
    skillId = tonumber(skillId) or 0
    if skillId <= 0 then
        return 0
    end
    if type(GetTradeskillIcon) == "function" then
        local ok, icon = pcall(GetTradeskillIcon, skillId)
        if ok == true then
            return tonumber(icon) or 0
        end
    end
    return 0
end

function Caps.GetCultivationIcon()
    return Caps.GetTradeSkillIcon(Caps.CultivationId())
end

function Caps.GetApothecaryIcon()
    return Caps.GetTradeSkillIcon(Caps.ApothecaryId())
end

function Caps.Level(skillId)
    local level = ReadLevel(skillId)
    return level
end

--- Live engine read (ignores sticky cache). Returns level, explicit.
--- explicit=true: a stock source reported a number, including 0 (unlearned).
--- explicit=false: sources missing/empty. Callers must not treat that 0 as a drop (#50 L14).
function Caps.ReadCultSkillLive()
    return ReadLevel(Caps.CultivationId())
end

function Caps.ReadApoSkillLive()
    return ReadLevel(Caps.ApothecaryId())
end

function Caps.GetCultSkill()
    HydrateStickyFromPersist()
    local live, explicit = ReadLevel(Caps.CultivationId())
    local out
    out, Caps._lastCult = StickLevel(live, explicit, Caps._lastCult)
    return out
end

function Caps.GetApoSkill()
    HydrateStickyFromPersist()
    local live, explicit = ReadLevel(Caps.ApothecaryId())
    local out
    out, Caps._lastApo = StickLevel(live, explicit, Caps._lastApo)
    return out
end

--- Call from LOADING_END so a later non-empty TRADE_SKILL_UPDATED can refresh.
function Caps.BeginLoadSkillRefresh()
    Caps._pendingLoadRefresh = true
    Caps._loadEmptyPulses = 0
end

--- GetTradeSkillLevel and TradeSkillLevels both report 0.
local function ExplicitZeroConfirmed(skillId)
    skillId = tonumber(skillId) or 0
    if skillId <= 0 then
        return false
    end
    local hits = 0
    local zeros = 0
    if type(GetTradeSkillLevel) == "function" then
        local ok, level = pcall(GetTradeSkillLevel, skillId)
        if ok == true and level ~= nil then
            hits = hits + 1
            if (tonumber(level) or 0) <= 0 then
                zeros = zeros + 1
            end
        end
    end
    if GameData and type(GameData.TradeSkillLevels) == "table" then
        local level = GameData.TradeSkillLevels[skillId]
        if level ~= nil then
            hits = hits + 1
            if (tonumber(level) or 0) <= 0 then
                zeros = zeros + 1
            end
        end
    end
    return hits >= 2 and zeros == hits
end

--- Explicit 0 sticks only when two sources agree, or on the second
--- consecutive pulse. A one-frame combat blip must not wipe sticky (ADP-1).
local function ResolveStickyLevel(skillId, live, explicit, prev, streakKey)
    live = tonumber(live) or 0
    prev = tonumber(prev) or 0
    if explicit == true and live <= 0 and prev > 0 then
        local streak = (tonumber(Caps[streakKey]) or 0) + 1
        Caps[streakKey] = streak
        if ExplicitZeroConfirmed(skillId) or streak >= 2 then
            Caps[streakKey] = 0
            return 0
        end
        return prev
    end
    Caps[streakKey] = 0
    if explicit == true or live > 0 then
        return live
    end
    return prev
end

--- Apply a TRADE_SKILL_UPDATED pulse.
--- Positive explicit levels update sticky immediately.
--- Explicit 0 waits for a second source or a second pulse (ADP-1).
--- Unknown empties never wipe sticky (combat / scenario blips).
function Caps.OnTradeSkillPulse()
    HydrateStickyFromPersist()
    local liveCult, cultExplicit = ReadLevel(Caps.CultivationId())
    local liveApo, apoExplicit = ReadLevel(Caps.ApothecaryId())
    local prevCult = tonumber(Caps._lastCult) or 0
    local prevApo = tonumber(Caps._lastApo) or 0
    local changed = false

    if Caps._pendingLoadRefresh == true then
        if cultExplicit == true or apoExplicit == true
            or liveCult > 0 or liveApo > 0
        then
            local newCult = prevCult
            local newApo = prevApo
            if cultExplicit == true or liveCult > 0 then
                newCult = ResolveStickyLevel(
                    Caps.CultivationId(), liveCult, cultExplicit, prevCult, "_cultZeroPulses")
            else
                Caps._cultZeroPulses = 0
            end
            if apoExplicit == true or liveApo > 0 then
                newApo = ResolveStickyLevel(
                    Caps.ApothecaryId(), liveApo, apoExplicit, prevApo, "_apoZeroPulses")
            else
                Caps._apoZeroPulses = 0
            end
            Caps._lastCult = newCult
            Caps._lastApo = newApo
            Caps._pendingLoadRefresh = false
            Caps._loadEmptyPulses = 0
            PersistSticky()
            changed = newCult ~= prevCult or newApo ~= prevApo
            if changed then
                local Bus = StockPiler.EventBus
                local E = StockPiler.Events
                if Bus and E and E.TRADE_SKILLS_CHANGED then
                    Bus.Fire(E.TRADE_SKILLS_CHANGED, { reason = "trade-caps" })
                end
            end
        else
            Caps._loadEmptyPulses = (tonumber(Caps._loadEmptyPulses) or 0) + 1
            -- Never clear sticky on empties: scenario/combat fires many empty
            -- TRADE_SKILL_UPDATED with no follow-up until the next skill-up.
            if Caps._loadEmptyPulses >= 5
                and prevCult <= 0
                and prevApo <= 0
            then
                Caps._pendingLoadRefresh = false
                Caps._loadEmptyPulses = 0
            elseif Caps._loadEmptyPulses >= 12 then
                Caps._pendingLoadRefresh = false
                Caps._loadEmptyPulses = 0
                if StockPiler.Debug and StockPiler.Debug.LogOp then
                    StockPiler.Debug.LogOp("caps", string.format(
                        "load-empty-keep sticky cult=%d apo=%d",
                        prevCult, prevApo
                    ))
                end
            end
        end
    else
        -- Trainer unlearn reports explicit 0 here (TRADE_SKILL_UPDATED).
        -- A single explicit 0 is not enough: levels blip to 0 in combat (ADP-1).
        if cultExplicit == true or liveCult > 0 then
            local nextCult = ResolveStickyLevel(
                Caps.CultivationId(), liveCult, cultExplicit, prevCult, "_cultZeroPulses")
            if nextCult ~= prevCult then
                changed = true
            end
            Caps._lastCult = nextCult
        else
            -- No reading this pulse: do not count toward consecutive zero streak (#35 L7).
            Caps._cultZeroPulses = 0
        end
        if apoExplicit == true or liveApo > 0 then
            local nextApo = ResolveStickyLevel(
                Caps.ApothecaryId(), liveApo, apoExplicit, prevApo, "_apoZeroPulses")
            if nextApo ~= prevApo then
                changed = true
            end
            Caps._lastApo = nextApo
        else
            Caps._apoZeroPulses = 0
        end
        if cultExplicit == true or apoExplicit == true
            or liveCult > 0 or liveApo > 0
        then
            PersistSticky()
        end
        if changed and StockPiler.Debug and StockPiler.Debug.LogOp then
            StockPiler.Debug.LogOp("caps", string.format(
                "sticky-update cult=%d->%d apo=%d->%d explicit=%s/%s",
                prevCult, tonumber(Caps._lastCult) or 0,
                prevApo, tonumber(Caps._lastApo) or 0,
                tostring(cultExplicit == true), tostring(apoExplicit == true)
            ))
        end
        if changed then
            local Bus = StockPiler.EventBus
            local E = StockPiler.Events
            if Bus and E and E.TRADE_SKILLS_CHANGED then
                Bus.Fire(E.TRADE_SKILLS_CHANGED, { reason = "trade-skill" })
            end
        end
    end
    if (tonumber(Caps._lastCult) or 0) > 0 or (tonumber(Caps._lastApo) or 0) > 0 then
        Caps._skillsReady = true
    end
end

function Caps.AreTradeSkillsReady()
    if Caps._skillsReady == true then
        return true
    end
    if Caps.GetCultSkill() > 0 or Caps.GetApoSkill() > 0 then
        Caps._skillsReady = true
        return true
    end
    return false
end

function Caps.MarkTradeSkillsReady()
    Caps.OnTradeSkillPulse()
    Caps.Refresh()
    if Caps.GetCultSkill() > 0 or Caps.GetApoSkill() > 0 then
        Caps._skillsReady = true
    end
end

function Caps.ResetTradeSkillsReady()
    Caps._skillsReady = false
    -- Keep _lastCult/_lastApo across combat/zone unless an explicit
    -- OnTradeSkillPulse replaces them. Avoids SkillUp rows vanishing when the
    -- engine briefly reports tradeSkills empty.
end

function Caps.CanAutoGrow()
    return Caps.GetCultSkill() > 0
end

function Caps.CanApothecary()
    return Caps.GetApoSkill() > 0
end

function Caps.CanBrewPotions()
    return Caps.CanApothecary()
end

function Caps.CanAutoBuy()
    return Caps.CanAutoGrow() or Caps.CanApothecary()
end

function Caps.LevelsHash()
    return tostring(Caps.GetCultSkill()) .. ":" .. tostring(Caps.GetApoSkill())
end
