dofile "engine/common/init_bgfx.lua"
local ltask = require "ltask"
local exclusive = require "ltask.exclusive"
local bgfx = require "bgfx"

local APIS = {
    "init",
    "dbg_text_clear",
    "dbg_text_print",
    "dbg_text_image",
    "frame",
    "shutdown",
    "request_screenshot",
    "reset",
    "set_debug",

    "encoder_frame",
}
local S = {}

function S.APIS()
    return APIS
end

local encoder = {}
local encoder_num = 0
local encoder_cur = 0
local encoder_frame = 0

local tokens = {}
local function wait_frame()
    local t = {}
    tokens[#tokens+1] = t
    ltask.wait(t)
end
local function wakeup_frame(...)
    for i, token in ipairs(tokens) do
        ltask.wakeup(token, ...)
        tokens[i] = nil
    end
end

function S.encoder_init()
    local who = ltask.current_session().from
    encoder[who] = nil
    encoder_num = encoder_num + 1
end

function S.encoder_release()
    local who = ltask.current_session().from
    if encoder[who] == encoder_frame then
        encoder_cur = encoder_cur - 1
    end
    encoder[who] = nil
    encoder_num = encoder_num - 1
end

function S.encoder_frame()
    local who = ltask.current_session().from
    if encoder[who] ~= encoder_frame then
        encoder[who] = encoder_frame
        encoder_cur = encoder_cur + 1
    end
    return wait_frame()
end

local pause_token
local continue_token

function S.pause()
    if pause_token then
        error "Can't pause twice."
    end
    pause_token = {}
    ltask.wait(pause_token)
    pause_token = nil
end

function S.continue()
    if not continue_token then
        error "Not pause."
    end
    ltask.wakeup(continue_token)
end

function S.frame()
    if not continue_token then
        error "Can only be used in pause."
    end
    return bgfx.frame()
end

ltask.fork(function()
    while true do
        ltask.sleep(0)
        if encoder_num > 0 and encoder_cur == encoder_num then
            encoder_frame = encoder_frame + 1
            encoder_cur = 0
            local f = bgfx.frame()
            if pause_token then
                ltask.wakeup(pause_token)
                continue_token = {}
                ltask.wait(continue_token)
                continue_token = nil
            end
            wakeup_frame(f)
        else
            exclusive.sleep(1)
        end
    end
end)

for _, name in ipairs(APIS) do
    if not S[name] then
        S[name] = bgfx[name]
    end
end

do
    local thread = require "thread"
    thread.newchannel "Bgfx"
    local bgfx_req = thread.channel_consume "Bgfx"
    local function request(ok, threadid, cmd, ...)
        if not ok then
            return
        end
        local f = S[cmd]
        if not f then
            return
        end
        local bgfx_resp = thread.channel_produce ("Bgfx-" .. threadid)
        bgfx_resp(f(...))
        return true
    end
    ltask.fork(function ()
        while true do
            if not request(bgfx_req:pop()) then
                ltask.sleep(10)
            end
        end
    end)
end

--[[
    do
        local thread = require "thread"
        local threadid = thread.id
        local bgfx_req = thread.channel_produce "Bgfx"
        thread.newchannel ("Bgfx-" .. threadid)
        local bgfx_resp = thread.channel_consume ("Bgfx-" .. threadid)
        local function call_bgfx(what, ...)
            bgfx_req(threadid, what, ...)
            return bgfx_resp()
        end
    end
]]

return S
