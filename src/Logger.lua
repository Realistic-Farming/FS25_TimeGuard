-- =========================================================
-- FS25_TimeGuard - Logger
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Small logging helper with a mod prefix and a debug gate.
-- Pattern mirrors the other Realistic Farming mods so log lines
-- are greppable by the "[TimeGuard]" tag.
-- =========================================================

TGLogger = TGLogger or {}
TGLogger.PREFIX = "[TimeGuard] "
TGLogger.debugEnabled = false

function TGLogger.info(msg, ...)
    if select("#", ...) > 0 then
        Logging.info(TGLogger.PREFIX .. msg, ...)
    else
        Logging.info(TGLogger.PREFIX .. msg)
    end
end

function TGLogger.warning(msg, ...)
    if select("#", ...) > 0 then
        Logging.warning(TGLogger.PREFIX .. msg, ...)
    else
        Logging.warning(TGLogger.PREFIX .. msg)
    end
end

function TGLogger.error(msg, ...)
    if select("#", ...) > 0 then
        Logging.error(TGLogger.PREFIX .. msg, ...)
    else
        Logging.error(TGLogger.PREFIX .. msg)
    end
end

function TGLogger.debug(msg, ...)
    if not TGLogger.debugEnabled then
        return
    end
    if select("#", ...) > 0 then
        Logging.info(TGLogger.PREFIX .. "[debug] " .. msg, ...)
    else
        Logging.info(TGLogger.PREFIX .. "[debug] " .. msg)
    end
end
