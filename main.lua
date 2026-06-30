

local function name() return "SCC" end

local icon = lcd.loadMask("scc.png")

-- ============================================================================
-- SCC PROTOCOL
-- ============================================================================

local FRAME_LEN  = 17
local CMD_HDR    = 0x9F
local RESP_HDR   = 0x05
local CODE_GET   = 0xE0
local CODE_SET   = 0xB2

local GET_FRAME = {0x9F,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
                   0x00,0x00,0x00,0x00,0x80,0x00,0xE0,0x1F}

local function reverseBits(b)
    b = b & 0xFF
    b = ((b >> 1) & 0x55) | ((b << 1) & 0xAA)
    b = ((b >> 2) & 0x33) | ((b << 2) & 0xCC)
    b = ((b >> 4) & 0x0F) | ((b << 4) & 0xF0)
    return b & 0xFF
end

local function calcChecksum(f)
    local s = 0
    for i = 2, 16 do s = (s - reverseBits(f[i])) & 0xFF end
    return reverseBits(s)
end

local function validateChecksum(f)
    local s = 0
    for i = 2, 17 do s = (s + reverseBits(f[i])) & 0xFF end
    return s == 0
end

local function buildGet()
    local f = {}
    for i = 1, FRAME_LEN do f[i] = GET_FRAME[i] end
    return f
end

local function buildSet(chId, prev)
    local f = {CMD_HDR, reverseBits(chId - 1), prev[3], prev[4], prev[5]}
    for i = 6, 15 do f[i] = GET_FRAME[i] end
    f[16] = CODE_SET
    f[17] = calcChecksum(f)
    return f
end

local function tableToBytes(t)
    local c = {}
    for i = 1, #t do c[i] = string.char(t[i]) end
    return table.concat(c)
end

local function bytesToTable(s)
    local t = {}
    for i = 1, #s do t[i] = string.byte(s, i) end
    return t
end

local function hexDump(t)
    local p = {}
    for i = 1, #t do p[i] = string.format("%02X", t[i]) end
    return table.concat(p, " ")
end

local function hexDumpStr(s)
    return hexDump(bytesToTable(s))
end

-- ============================================================================
-- TRANSPORT 
-- ============================================================================

local widget = {
    conn = nil,
    openErr = nil,
    currentId = nil,
    targetId = 1,
    lastResponse = nil,
    status = "Press READ",
    lastTx = "",
    lastRx = "",
    fStatus = nil, fId = nil, fTarget = nil, fTx = nil, fRx = nil,
}

local function setStatus(s)
    widget.status = s
    if widget.fStatus then widget.fStatus:value(s) end
    print("[SCC] " .. s)
end

local function setIdLine(s)
    if widget.fId then widget.fId:value(s) end
end

local function setTxLine(s)
    widget.lastTx = s
    if widget.fTx then widget.fTx:value("TX: " .. s) end
end

local function setRxLine(s)
    widget.lastRx = s
    if widget.fRx then widget.fRx:value("RX: " .. s) end
end

local function ensureOpen()
    if widget.conn then return true end
    if not serial or not serial.open then
        widget.openErr = "no serial API"
        return false
    end
    -- Documented signature: open(name, baudrate, mode, power)
    -- power=true supplies VCC to power the connected SBUS device.
    local ok, conn = pcall(function()
        return serial.open("sport", 9600, "8E2", true)
    end)
    if not ok then
        widget.openErr = "open() raised: " .. tostring(conn)
        return false
    end
    if not conn then
        widget.openErr = "open() returned nil"
        return false
    end
    widget.conn = conn
    print("[SCC] port opened: sport 9600 8E2 power=true")
    return true
end


local function closePort()
    if widget.conn then
        pcall(function()
            if widget.conn.close then
                widget.conn:close()
            end
        end)
        widget.conn = nil
        collectgarbage()
        print("[SCC] port closed")
    end
end

-- Drain into accumulator until total reaches FRAME_LEN starting at first
-- occurrence of RESP_HDR (0x05). Skips TX echo and any pre-existing junk.
local function readResponse(timeoutSec)
    local rx = ""
    local deadline = os.clock() + (timeoutSec or 0.20)
    while os.clock() < deadline do
        if not widget.conn:empty() then
            local chunk = widget.conn:read()
            if chunk and #chunk > 0 then rx = rx .. chunk end
        end
        local startIdx = nil
        for i = 1, #rx do
            if string.byte(rx, i) == RESP_HDR then
                startIdx = i
                break
            end
        end
        if startIdx and (#rx - startIdx + 1) >= FRAME_LEN then
            local frame = string.sub(rx, startIdx, startIdx + FRAME_LEN - 1)
            return bytesToTable(frame), nil, rx
        end
    end
    return nil, string.format("timeout %d byte(s)", #rx), rx
end

local MAX_TRIES = 4

local function smallDelay(sec)
    local t0 = os.clock()
    while os.clock() - t0 < sec do end
end

-- Single-shot READ. Returns (true) on success, (false, errMsg) on failure.
-- Side effects: updates fTx/fRx/fId, and on success widget.currentId & widget.lastResponse.
local function readOnce()
    if not ensureOpen() then return false, widget.openErr or "?" end
    widget.conn:flush()

    local txTbl = buildGet()
    setTxLine(hexDump(txTbl))
    print("[SCC] TX: " .. hexDump(txTbl))
    widget.conn:write(tableToBytes(txTbl))

    local resp, err, rawRx = readResponse(0.20)
    setRxLine(rawRx and #rawRx > 0 and hexDumpStr(rawRx) or "(empty)")
    if not resp then return false, "timeout " .. err end
    print("[SCC] RX: " .. hexDump(resp))

    if not validateChecksum(resp) then return false, "checksum" end

    widget.lastResponse = resp
    widget.currentId = reverseBits(resp[2]) + 1
    setIdLine("Current ID: " .. widget.currentId)
    return true
end

-- Single-shot WRITE+verify. Returns (true) on success, (false, errMsg) on fail.
local function writeOnce()
    if not widget.lastResponse then return false, "no prior response" end
    if not ensureOpen() then return false, widget.openErr or "?" end

    widget.conn:flush()
    local frame = buildSet(widget.targetId, widget.lastResponse)
    setTxLine(hexDump(frame))
    print("[SCC] TX(set): " .. hexDump(frame))
    widget.conn:write(tableToBytes(frame))

    -- Let the device process the SET before verify-read
    smallDelay(0.05)

    local ok, err = readOnce()
    if not ok then return false, "verify: " .. err end
    if widget.currentId ~= widget.targetId then
        return false, "got ID " .. tostring(widget.currentId)
    end
    return true
end

local function doRead()
    local lastErr = "?"
    for i = 1, MAX_TRIES do
        setStatus(string.format("Reading (%d/%d)...", i, MAX_TRIES))
        local ok, err = readOnce()
        if ok then
            setStatus(string.format("OK: ID = %d  (try %d/%d)",
                                    widget.currentId, i, MAX_TRIES))
            closePort()
            return
        end
        lastErr = err
        smallDelay(0.05)
    end
    setStatus(string.format("READ failed %d tries: %s", MAX_TRIES, lastErr))
    closePort()
end

local function doWrite()
    if not widget.lastResponse then
        setStatus("READ first - need previous response")
        return
    end
    if widget.targetId < 1 or widget.targetId > 16 then
        setStatus("Target must be 1..16")
        return
    end

    local lastErr = "?"
    for i = 1, MAX_TRIES do
        setStatus(string.format("Writing %d (%d/%d)...", widget.targetId, i, MAX_TRIES))
        local ok, err = writeOnce()
        if ok then
            setStatus(string.format("OK: ID set to %d  (try %d/%d)",
                                    widget.targetId, i, MAX_TRIES))
            closePort()
            return
        end
        lastErr = err
        smallDelay(0.05)
    end
    setStatus(string.format("WRITE failed %d tries: %s", MAX_TRIES, lastErr))
    closePort()
end

-- ============================================================================
-- FORM
-- ============================================================================

local function create()
    local line

    line = form.addLine("Status")
    widget.fStatus = form.addStaticText(line, nil, widget.status)

    line = form.addLine("ID")
    widget.fId = form.addStaticText(line, nil, "(unknown)")

    line = form.addLine("Target ID")
    widget.fTarget = form.addNumberField(line, nil, 1, 16,
        function() return widget.targetId end,
        function(v) widget.targetId = v end)
    widget.fTarget:enableInstantChange(false)

    -- One button per line (X20S screen / multi-button-on-line is finicky)
    line = form.addLine("")
    form.addTextButton(line, nil, "READ", doRead)

    line = form.addLine("")
    form.addTextButton(line, nil, "WRITE", doWrite)

    -- Debug lines (visible on screen since we have no USB debug)
    line = form.addLine("TX")
    widget.fTx = form.addStaticText(line, nil, "TX: (none)")

    line = form.addLine("RX")
    widget.fRx = form.addStaticText(line, nil, "RX: (none)")

    return widget
end

local function wakeup() end
local function event(_, _, _) return false end

local function init()
    system.registerSystemTool({
        name   = name,
        icon   = icon,
        create = create,
        wakeup = wakeup,
        event  = event,
    })
end

local function destroy()
    closePort()
end

return {
    init = init,
    destroy = destroy
}
