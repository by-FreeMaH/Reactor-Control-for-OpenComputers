-- Reactor Control v1.2 build 1
-- ⚙
-- ⓘ

-- ----------------------------------------------------------------------------------------------------
-- ЗАГРУЗКА МОДУЛЕЙ
-- ----------------------------------------------------------------------------------------------------
local computer = require("computer")
local image = require("image")
local buffer = require("doubleBuffering")
local shell = require("shell")
local event = require("event")
local component = require("component")
local fs = require("filesystem")
local term = require("term")
local unicode = require("unicode")
local bit = require("bit32")
local thread = require("thread")

-- ----------------------------------------------------------------------------------------------------
-- КОНФИГУРАЦИЯ И КОНСТАНТЫ
-- ----------------------------------------------------------------------------------------------------
local VERSION = "1.2"
local BUILD = "1"
local PROGRAM_VERSION = VERSION .. "." .. BUILD
local UPDATE_CHECK_INTERVAL = 3600  -- Проверка обновлений каждый час
local SUPPORTERS_UPDATE_INTERVAL = 600  -- Обновление спонсоров каждые 10 минут
local FLUID_CHECK_INTERVAL = 60  -- Проверка жидкости каждую минуту
local MAX_REACTORS = 12
local DEFAULT_POROG = 50000

-- UI конфигурация
local UI = {
    resolution = {x = 160, y = 50},
    widgets = {
        start = {x = 10, y = 6, width = 22, height = 11, spacing = 25},
        rows = 3,
        cols = 4
    },
    status = {x = 87, y = 44, width = 31, height = 6},
    console = {x = 123, y = 3, width = 35, height = 24},
    fluidInfo = {x = 123, y = 27, width = 35, height = 6},
    porogControl = {x = 123, y = 32, width = 35, height = 4},
    fluxInfo = {x = 123, y = 36, width = 35, height = 4},
    rfInfo = {x = 123, y = 40, width = 35, height = 4},
    timeInfo = {x = 123, y = 45, width = 35, height = 4},
    buttons = {
        stop = {x = 10, y = 44, width = 24, height = 3},
        start = {x = 38, y = 44, width = 24, height = 3},
        restart = {x = 10, y = 47, width = 24, height = 3},
        exit = {x = 38, y = 47, width = 24, height = 3},
        theme = {x = 66, y = 44, width = 18, height = 3},
        metric = {x = 66, y = 47, width = 18, height = 3},
        settings = {x = 3, y = 44, width = 4, height = 3},
        info = {x = 3, y = 47, width = 4, height = 3}
    }
}

-- Цветовая схема
local COLORS = {
    dark = {
        bg = 0x202020,
        bg2 = 0x101010,
        bg3 = 0x3c3c3c,
        bg4 = 0x969696,
        text = 0xcccccc,
        textBtn = 0xffffff,
        msgInfo = 0x61ff52,
        msgWarn = 0xfff700,
        msgError = 0xff0000,
        statusWork = 0x61ff52,
        statusStop = 0xfd3232
    },
    light = {
        bg = 0x000000,
        bg2 = 0x202020,
        bg3 = 0xffffff,
        bg4 = 0x5a5a5a,
        text = 0x3f3f3f,
        textBtn = 0x303030,
        msgInfo = 0x61ff52,
        msgWarn = 0xfff700,
        msgError = 0xff0000,
        statusWork = 0x61ff52,
        statusStop = 0xfd3232
    }
}

-- Пороги времени для предупреждений
local TIME_THRESHOLDS = {
    good = 3600,   -- >1 час - зеленый
    warn = 600,    -- >10 минут - желтый
    error = 0      -- <10 минут - красный
}

-- ----------------------------------------------------------------------------------------------------
-- ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
-- ----------------------------------------------------------------------------------------------------
buffer.setResolution(UI.resolution.x, UI.resolution.y)
buffer.clear(0x000000)

local state = {
    exit = false,
    uptime = computer.uptime(),
    lastUpdate = computer.uptime(),
    lastFluidCheck = computer.uptime(),
    lastSupportersUpdate = computer.uptime(),
    lastUpdateCheck = computer.uptime(),
    second = 0,
    minute = 0,
    hour = 0,
    work = false,
    starting = false,
    offFluid = false,
    anyReactorOn = false,
    anyReactorOff = false,
    depletionTime = 0,
    consumeSecond = 0,
    reason = nil,
    theme = false,
    metric = 0,
    statusMetric = "Auto",
    metricRf = "Rf",
    metricMb = "Mb",
    porog = DEFAULT_POROG,
    updateCheck = true,
    debugLog = false,
    users = {},
    usersOld = {},
    maxThreshold = 10^12,
    fluidInMe = 0,
    lastValidFluid = 0,
    currentMeAddress = nil
}

-- Кэш для оптимизации
local cache = {
    supporters = nil,
    supportersTimestamp = 0,
    changelog = nil,
    changelogTimestamp = 0,
    reactorData = {}
}

-- Компоненты
local components = {
    meNetwork = false,
    meProxy = nil,
    fluxNetwork = false,
    chatBox = nil,
    isChatBox = false,
    reactors = {},
    reactorCount = 0
}

-- ----------------------------------------------------------------------------------------------------
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ----------------------------------------------------------------------------------------------------

-- Форматирование времени
local function secondsToHMS(totalSeconds)
    if type(totalSeconds) ~= "number" or totalSeconds < 0 then
        return "00:00:00"
    end
    local hours = math.floor(totalSeconds / 3600)
    local minutes = math.floor((totalSeconds % 3600) / 60)
    local seconds = math.floor(totalSeconds % 60)
    return string.format("%02d:%02d:%02d", hours, minutes, seconds)
end

-- Безопасный вызов методов компонентов
local function safeCall(proxy, method, default, ...)
    if not proxy or not proxy[method] then
        return default
    end
    
    local ok, result = pcall(proxy[method], proxy, ...)
    if ok and result ~= nil then
        if type(default) == "number" then
            local numberResult = tonumber(result)
            return numberResult or default
        else
            return result
        end
    else
        -- Логирование ошибки
        if state.debugLog then
            local logFile = io.open("/home/reactor_errors.log", "a")
            if logFile then
                logFile:write(string.format("[%s] Method '%s' failed: %s\n",
                    os.date("%Y-%m-%d %H:%M:%S"), tostring(method), tostring(result)))
                logFile:close()
            end
        end
        return default
    end
end

-- Линейная интерполяция цветов
local function lerpColor(c1, c2, t)
    local r1, g1, b1 = bit.rshift(c1, 16) % 0x100, bit.rshift(c1, 8) % 0x100, c1 % 0x100
    local r2, g2, b2 = bit.rshift(c2, 16) % 0x100, bit.rshift(c2, 8) % 0x100, c2 % 0x100
    local r = r1 + (r2 - r1) * t
    local g = g1 + (g2 - g1) * t
    local b = b1 + (b2 - b1) * t
    return bit.lshift(math.floor(r), 16) + bit.lshift(math.floor(g), 8) + math.floor(b)
end

-- Круглая функция
local function round(num, digits)
    local mult = 10 ^ (digits or 0)
    local result = math.floor(num * mult + 0.5) / mult
    return result == math.floor(result) and math.floor(result) or result
end

-- ----------------------------------------------------------------------------------------------------
-- РАБОТА С КОНФИГУРАЦИЕЙ
-- ----------------------------------------------------------------------------------------------------

local function loadConfig()
    local configPath = "/home/data/config.lua"
    local defaultConfig = {
        porog = DEFAULT_POROG,
        users = {},
        usersOld = {},
        theme = false,
        updateCheck = true,
        debugLog = false
    }
    
    -- Создание директорий если их нет
    if not fs.exists("/home/data") then
        fs.makeDirectory("/home/data")
    end
    
    if not fs.exists(configPath) then
        local file = io.open(configPath, "w")
        if file then
            file:write("-- Конфигурация программы Reactor Control v" .. VERSION .."\n")
            file:write("-- Прежде чем что-то изменять, пожалуйста внимательно читайте описание!\n\n")
            file:write("porog = " .. DEFAULT_POROG .. " -- Минимальное значение порога жидкости в mB\n\n")
            file:write("-- Впишите никнеймы игроков которым будет разрешеннен доступ к ПК, обязательно ради вашей безопасности!\n")
            file:write("users = {} -- Пример: {\"P1KaChU337\", \"Nickname1\"} -- Именно что с кавычками и запятыми!\n")
            file:write("usersOld = {} -- Не трогайте, может заблокировать ПК!\n\n")
            file:write("-- Тема интерфейса в системе по стандарту\n")
            file:write("theme = false -- (false темная, true светлая)\n\n")
            file:write("updateCheck = true -- (false не проверять на наличие обновлений, true проверять обновления)\n\n")
            file:write("debugLog = false\n\n")
            file:write("-- После внесение изменений сохраните данные (Ctrl+S) и выйдите из редактора (Ctrl+W)\n")
            file:write("-- Если в будущем захотите поменять данные то пропишите \"cd data\" затем \"edit config.lua\"\n")
            file:close()
            
            -- Открытие редактора для настройки
            shell.setWorkingDirectory("/home/data")
            shell.execute("edit config.lua")
            shell.setWorkingDirectory("/home")
        else
            io.stderr:write("Ошибка: не удалось создать файл " .. configPath .. "\n")
        end
    end
    
    -- Загрузка конфигурации
    local ok, config = pcall(dofile, configPath)
    if not ok then
        io.stderr:write("Ошибка загрузки конфига: " .. tostring(config) .. "\n")
        return defaultConfig
    end
    
    -- Применение значений по умолчанию для отсутствующих параметров
    for k, v in pairs(defaultConfig) do
        if config[k] == nil then
            config[k] = v
        end
    end
    
    return config
end

local function saveConfig()
    local configPath = "/home/data/config.lua"
    local file = io.open(configPath, "w")
    if not file then
        io.stderr:write("Ошибка: не удалось открыть файл для записи.\n")
        return
    end

    file:write("-- Конфигурация программы Reactor Control v" .. VERSION .."\n")
    file:write("-- Прежде чем что-то изменять, пожалуйста внимательно читайте описание!\n\n")
    file:write(string.format("porog = %d -- Минимальное значение порога жидкости в mB\n\n", math.max(0, state.porog)))
    
    -- Пользователи
    file:write("-- Впишите никнеймы игроков которым будет разрешеннен доступ к ПК, обязательно ради вашей безопасности!\n")
    file:write("users = {")
    for i, user in ipairs(state.users) do
        file:write(string.format("%q", user))
        if i < #state.users then
            file:write(", ")
        end
    end
    file:write("} -- Пример: {\"P1KaChU337\", \"Nickname1\"} -- Именно что с кавычками и запятыми!\n")

    file:write("usersOld = {")
    for i, user in ipairs(state.usersOld) do
        file:write(string.format("%q", user))
        if i < #state.usersOld then
            file:write(", ")
        end
    end
    file:write("} -- Не трогайте вообще, даже при удалении пользователей, оставьте оно само очистится, можно трогать только users но не usersOld, может заблокировать ПК!\n\n")
    
    -- Тема
    file:write("-- Тема интерфейса в системе по стандарту\n")
    file:write(string.format("theme = %s -- Тема интерфейса (false тёмная, true светлая)\n\n", tostring(state.theme)))
    file:write(string.format("updateCheck = %s -- (false не проверять на наличие обновлений, true проверять обновления)\n\n", tostring(state.updateCheck)))
    file:write(string.format("debugLog = %s\n\n", tostring(state.debugLog)))
    file:write("-- После внесение изменений сохраните данные (Ctrl+S) и выйдите из редактора (Ctrl+W)\n")
    file:write("-- Для запуска основой программы перейдите в домашнюю директорию \"cd ..\", и напишите \"main.lua\"\n")
    
    file:close()
end

-- ----------------------------------------------------------------------------------------------------
-- ИНИЦИАЛИЗАЦИЯ КОМПОНЕНТОВ
-- ----------------------------------------------------------------------------------------------------

local function initReactors()
    components.reactors = {}
    components.reactorCount = 0
    
    for address in component.list("htc_reactors") do
        if components.reactorCount >= MAX_REACTORS then break end
        
        components.reactorCount = components.reactorCount + 1
        local proxy = component.proxy(address)
        
        table.insert(components.reactors, {
            address = address,
            proxy = proxy,
            temperature = 0,
            type = "Air",
            rfGeneration = 0,
            work = false,
            aborted = false,
            depletionTime = 0,
            coolant = {
                current = 0,
                max = 1
            }
        })
    end
    
    -- Инициализация данных для всех реакторов
    for i = 1, components.reactorCount do
        local reactor = components.reactors[i]
        reactor.type = safeCall(reactor.proxy, "isActiveCooling", false) and "Fluid" or "Air"
        reactor.coolant.max = safeCall(reactor.proxy, "getMaxFluidCoolant", 1)
    end
end

local function initMeNetwork()
    components.meNetwork = component.isAvailable("me_controller") or component.isAvailable("me_interface")
    
    if components.meNetwork then
        if component.isAvailable("me_controller") then
            local addr = component.list("me_controller")()
            components.meProxy = component.proxy(addr)
            state.currentMeAddress = addr
        elseif component.isAvailable("me_interface") then
            local addr = component.list("me_interface")()
            components.meProxy = component.proxy(addr)
            state.currentMeAddress = addr
        else
            components.meProxy = nil
            state.currentMeAddress = nil
        end
    else
        state.offFluid = true
        state.reason = "МЭ не найдена!"
    end
    
    return state.currentMeAddress
end

local function initFluxNetwork()
    components.fluxNetwork = component.isAvailable("flux_controller")
end

local function initChatBox()
    state.isChatBox = component.isAvailable("chat_box")
    if state.isChatBox then
        components.chatBox = component.chat_box
        components.chatBox.setName("§6§lКомплекс§7§o")
    end
end

-- ----------------------------------------------------------------------------------------------------
-- РАБОТА С ЖИДКОСТЯМИ
-- ----------------------------------------------------------------------------------------------------

local function checkFluidLevel()
    if not components.meNetwork then
        state.offFluid = true
        state.reason = "МЭ не найдена!"
        return
    end

    if not components.meProxy then
        initMeNetwork()
        if not components.meProxy then
            state.offFluid = true
            state.reason = "Нет прокси МЭ!"
            return
        end
    end

    local ok, items = pcall(components.meProxy.getItemsInNetwork, { name = "ae2fc:fluid_drop" })
    if not ok or type(items) ~= "table" then
        state.offFluid = true
        state.reason = "Ошибка жидкости!"
        return
    end

    local targetFluid = "low_temperature_refrigerant"
    local count = 0

    for _, item in ipairs(items) do
        if item.label and item.label:find(targetFluid) then
            count = count + (item.size or 0)
        end
    end

    if count > state.maxThreshold then
        count = state.lastValidFluid
    else
        state.lastValidFluid = count
    end

    state.fluidInMe = count

    if count == 0 then
        state.offFluid = true
        state.reason = "Нет хладагента!"
    end

    if count <= state.porog then
        if not state.ismechecked then
            message("Жидкости в МЭ меньше порога!", COLORS[state.theme].msgWarn)
            for i = 1, components.reactorCount do
                local reactor = components.reactors[i]
                if reactor.type == "Fluid" and reactor.work then
                    message("Отключаю жидкостные реакторы...", COLORS[state.theme].text)
                    break
                end
            end
        end
        state.offFluid = true
        state.reason = "Нет хладагента!"
        state.ismechecked = true
    else
        if state.offFluid and state.starting then
            message("Жидкости хватает, включаю реакторы...", COLORS[state.theme].text)
            state.offFluid = false
            state.ismechecked = false
            for i = 1, components.reactorCount do
                local reactor = components.reactors[i]
                if reactor.type == "Fluid" then
                    startReactor(i)
                    reactor.aborted = false
                    updateReactorData(i)
                end
            end
        end
        if state.offFluid then 
            state.offFluid = false 
            for i = 1, components.reactorCount do
                local reactor = components.reactors[i]
                if reactor.type == "Fluid" and reactor.aborted then
                    reactor.aborted = false
                    updateReactorData(i)
                end
            end
        end
    end
end

-- ----------------------------------------------------------------------------------------------------
-- ИНТЕРФЕЙС
-- ----------------------------------------------------------------------------------------------------

local function drawBrailleChar(x, y, dots, color)
    buffer.drawText(x, y, color, unicode.char(
        10240 +
        (dots[8] or 0) * 128 +
        (dots[7] or 0) * 64 +
        (dots[6] or 0) * 32 +
        (dots[4] or 0) * 16 +
        (dots[2] or 0) * 8 +
        (dots[5] or 0) * 4 +
        (dots[3] or 0) * 2 +
        (dots[1] or 0)
    ))
end

local function drawAnimatedButton(push, x, y, text, width, color, textColor)
    local btnHeight = 3
    local bgColor = color or (state.theme and 0x059bff or 0x38afff)
    local tColor = textColor or COLORS[state.theme].textBtn
    
    -- Фон кнопки
    buffer.drawRectangle(x, y + 1, width, 1, bgColor, 0, " ")
    
    -- Левая граница
    drawBrailleChar(x - 1, y, {0,0,0,0,1,1,1,1}, bgColor)
    drawBrailleChar(x - 1, y + 1, {1,1,1,1,1,1,1,1}, bgColor)
    drawBrailleChar(x - 1, y + 2, {1,1,0,1,0,0,0,0}, bgColor)

    -- Правая граница
    drawBrailleChar(x + width, y, {0,0,0,0,1,1,1,1}, bgColor)
    drawBrailleChar(x + width, y + 1, {1,1,1,1,1,1,1,1}, bgColor)
    drawBrailleChar(x + width, y + 2, {1,1,1,0,0,0,0,0}, bgColor)

    -- Верхняя и нижняя границы
    for i = 0, width - 1 do
        drawBrailleChar(x + i, y, bgColor, {0,0,0,0,1,1,1,1})
        drawBrailleChar(x + i, y + 2, bgColor, {1,1,1,1,0,0,0,0})
    end

    -- Текст
    local textX = x + math.floor((width - unicode.len(text)) / 2)
    buffer.drawText(textX, y + 1, tColor, text)
    
    if push == 0 then
        os.sleep(0.1)
    end
end

local function drawWidgets()
    if components.reactorCount <= 0 then
        buffer.drawRectangle(UI.widgets.start.x - 1, UI.widgets.start.y - 1, 
                           UI.widgets.cols * UI.widgets.start.width + (UI.widgets.cols - 1) * UI.widgets.start.spacing + 2, 
                           UI.widgets.rows * UI.widgets.start.height + (UI.widgets.rows - 1) * UI.widgets.start.spacing + 2, 
                           COLORS[state.theme].bg4, 0, " ")
        buffer.drawRectangle(37, 19, 50, 3, COLORS[state.theme].bg2, 0, " ")
        buffer.drawRectangle(36, 20, 52, 1, COLORS[state.theme].bg2, 0, " ")
        
        local cornerPos = {
            {36, 19, {1,1,1,0,1,0,1,0}},
            {87, 19, {1,0,1,1,0,1,0,1}},
            {87, 21, {1,1,0,1,0,0,1,1}},
            {36, 21, {1,0,1,0,1,0,1,0}}
        }
        
        for _, c in ipairs(cornerPos) do
            drawBrailleChar(c[1], c[2], c[3], COLORS[state.theme].bg2)
        end
        
        buffer.drawText(43, 20, COLORS[state.theme].text, "У вас не подключенно ни одного реактора!")
        buffer.drawText(40, 20, 0xffd900, "⚠")
        return
    end

    buffer.drawRectangle(UI.widgets.start.x - 1, UI.widgets.start.y - 1, 
                       UI.widgets.cols * UI.widgets.start.width + (UI.widgets.cols - 1) * UI.widgets.start.spacing + 2, 
                       UI.widgets.rows * UI.widgets.start.height + (UI.widgets.rows - 1) * UI.widgets.start.spacing + 2, 
                       COLORS[state.theme].bg4, 0, " ")

    for i = 1, math.min(components.reactorCount, MAX_REACTORS) do
        local row = math.ceil(i / UI.widgets.cols)
        local col = (i - 1) % UI.widgets.cols + 1
        local x = UI.widgets.start.x + (col - 1) * (UI.widgets.start.width + UI.widgets.start.spacing)
        local y = UI.widgets.start.y + (row - 1) * (UI.widgets.start.height + UI.widgets.start.spacing)
        
        local reactor = components.reactors[i]
        
        -- Фон виджета
        buffer.drawRectangle(x + 1, y, 20, 11, COLORS[state.theme].bg, 0, " ")
        buffer.drawRectangle(x, y + 1, 22, 9, COLORS[state.theme].bg, 0, " ")
        
        -- Углы
        drawBrailleChar(x, y, {1,1,1,0,1,0,1,0}, COLORS[state.theme].bg)
        drawBrailleChar(x + 21, y, {1,0,1,1,0,1,0,1}, COLORS[state.theme].bg)
        drawBrailleChar(x + 21, y + 10, {1,1,0,1,0,0,1,1}, COLORS[state.theme].bg)
        drawBrailleChar(x, y + 10, {1,0,1,0,1,0,1,0}, COLORS[state.theme].bg)

        -- Информация о реакторе
        buffer.drawText(x + 6, y + 1, COLORS[state.theme].text, "Реактор #" .. i)
        buffer.drawText(x + 4, y + 3, COLORS[state.theme].text, "Нагрев: " .. reactor.temperature .. "°C")
        buffer.drawText(x + 4, y + 4, COLORS[state.theme].text, formatRFWidget(reactor.rfGeneration))
        buffer.drawText(x + 4, y + 5, COLORS[state.theme].text, "Тип: " .. reactor.type)
        buffer.drawText(x + 4, y + 6, COLORS[state.theme].text, "Запущен: " .. (reactor.work and "Да" or "Нет"))
        buffer.drawText(x + 4, y + 7, COLORS[state.theme].text, "Распад: " .. secondsToHMS(reactor.depletionTime))
        
        -- Кнопка управления
        local buttonColor = reactor.work and 0xfd3232 or 0x2beb1a
        drawAnimatedButton(1, x + 6, y + 8, (reactor.work and "Отключить" or "Включить"), 10, buttonColor)
        
        -- Прогресс-бар для жидкостных реакторов
        if reactor.type == "Fluid" then
            drawVerticalProgressBar(x + 1, y + 1, 9, reactor.coolant.current, reactor.coolant.max, 0x0044FF, 0x00C8FF, COLORS[state.theme].bg2)
        end
    end
end

-- ----------------------------------------------------------------------------------------------------
-- ОСНОВНЫЕ ФУНКЦИИ
-- ----------------------------------------------------------------------------------------------------

local function message(msg, color)
    color = color or COLORS[state.theme].text
    msg = tostring(msg)
    
    -- Добавляем сообщение в консоль
    table.insert(consoleLines, {
        text = msg,
        color = color
    })
    
    -- Ограничиваем количество строк
    if #consoleLines > 20 then
        table.remove(consoleLines, 1)
    end
    
    drawRightMenu()
end

local function startReactor(num)
    if num then
        message("Запускаю реактор #" .. num .. "...", COLORS[state.theme].text)
    else
        message("Запуск реакторов...", COLORS[state.theme].text)
    end
    
    for i = num or 1, num or components.reactorCount do
        local reactor = components.reactors[i]
        local proxy = reactor.proxy

        if reactor.type == "Fluid" then
            if not state.offFluid then
                safeCall(proxy, "activate")
                reactor.work = true
                if num then
                    message("Реактор #" .. i .. " (жидкостный) запущен!", COLORS[state.theme].msgInfo)
                end
            else
                if state.fluidInMe <= state.porog then
                    if num then
                        message("Ошибка по жидкости! Реактор #" .. i .. " (жидкостный) не был запущен!", COLORS[state.theme].msgWarn)
                    end
                    state.offFluid = true
                    if not state.reason then
                        state.reason = "Ошибка жидкости!"
                        reactor.aborted = true
                    end
                else
                    state.offFluid = false
                    safeCall(proxy, "activate")
                    reactor.work = true
                    if num then
                        message("Реактор #" .. i .. " (жидкостный) запущен!", COLORS[state.theme].msgInfo)
                    end
                end
            end
        else
            safeCall(proxy, "activate")
            reactor.work = true
            if num then
                message("Реактор #" .. i .. " (воздушный) запущен!", COLORS[state.theme].msgInfo)
            end
        end
    end
end

local function stopReactor(num)
    if num then
        message("Отключаю реактор #" .. num .. "...", COLORS[state.theme].text)
    else
        message("Отключение реакторов...", COLORS[state.theme].text)
    end
    
    for i = num or 1, num or components.reactorCount do
        local reactor = components.reactors[i]
        local proxy = reactor.proxy
        
        safeCall(proxy, "deactivate")
        reactor.work = false
        
        if reactor.type == "Fluid" then
            if num then
                message("Реактор #" .. i .. " (жидкостный) отключен!", COLORS[state.theme].msgInfo)
            end
        else
            if num then
                message("Реактор #" .. i .. " (воздушный) отключен!", COLORS[state.theme].msgInfo)
            end
        end
    end
end

local function updateReactorData(num)
    for i = num or 1, num or components.reactorCount do
        local reactor = components.reactors[i]
        local proxy = reactor.proxy
        
        reactor.temperature = safeCall(proxy, "getTemperature", 0)
        reactor.rfGeneration = safeCall(proxy, "getEnergyGeneration", 0)
        reactor.work = safeCall(proxy, "hasWork", false)

        if reactor.type == "Fluid" then
            reactor.coolant.current = safeCall(proxy, "getFluidCoolant", 0)
            reactor.coolant.max = safeCall(proxy, "getMaxFluidCoolant", 1)
        end
    end
end

-- ----------------------------------------------------------------------------------------------------
-- ОСНОВНОЙ ЦИКЛ
-- ----------------------------------------------------------------------------------------------------

local function main()
    -- Загрузка конфигурации
    local config = loadConfig()
    state.porog = config.porog
    state.users = config.users
    state.usersOld = config.usersOld
    state.theme = config.theme
    state.updateCheck = config.updateCheck
    state.debugLog = config.debugLog
    
    -- Инициализация
    initReactors()
    initMeNetwork()
    initFluxNetwork()
    initChatBox()
    
    -- Основной цикл
    while not state.exit do
        local now = computer.uptime()
        local deltaTime = now - state.lastUpdate
        
        -- Обновление каждую секунду
        if deltaTime >= 1 then
            state.lastUpdate = now
            state.second = state.second + 1
            
            -- Минутные обновления
            if state.second >= 60 then
                state.minute = state.minute + 1
                state.second = 0
                
                -- Проверка жидкости каждую минуту
                if state.minute % (FLUID_CHECK_INTERVAL / 60) == 0 then
                    checkFluidLevel()
                end
                
                -- Обновление спонсоров каждые 10 минут
                if state.minute % (SUPPORTERS_UPDATE_INTERVAL / 60) == 0 then
                    -- updateSupporters()
                end
                
                -- Проверка обновлений каждый час
                if state.minute % (UPDATE_CHECK_INTERVAL / 60) == 0 and state.updateCheck then
                    -- checkForUpdates()
                end
                
                -- Ежечасные события
                if state.minute >= 60 then
                    state.hour = state.hour + 1
                    state.minute = 0
                end
            end
            
            -- Обновление данных реакторов
            updateReactorData()
            
            -- Отрисовка интерфейса
            drawWidgets()
        end
        
        -- Обработка событий
        local eventData = {event.pull(0.05)}
        local eventType = eventData[1]
        
        if eventType == "touch" then
            local _, _, x, y = table.unpack(eventData)
            handleTouch(x, y)
        end
        
        if eventType == "interrupted" then
            onInterrupt()
        end
        
        os.sleep(0)
    end
end

-- Запуск программы
main()
