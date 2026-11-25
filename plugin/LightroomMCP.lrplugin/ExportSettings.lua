-- Export dialog settings that export_photos accepts in its `settings` argument.
--
-- Keys are LrExportSession settings without their `LR_` prefix, spelled as
-- Lightroom writes them in an .lrtemplate file (format, jpeg_quality,
-- tokens, ...), so a value read from a preset (list_export_presets with
-- include_settings) can be passed back unchanged.
--
-- Every value is type-checked before an export starts: a setting of the wrong
-- type can hang the export session with no error or dialog (see
-- ExportPresets.invalidSetting). Settings that decide where files go or what
-- happens after the export (destination, collision handling, post-processing,
-- re-import, export service) are not accepted here; they have their own
-- arguments or are fixed by the tool.
local ExportSettings = {}

local function oneOf(...)
    local set = {}
    for _, v in ipairs({ ... }) do set[v] = true end
    return set
end

-- kind: "boolean", "number", "integer" or "string".
-- min/max bound numbers (inclusive) and minExclusive refuses the bound itself.
-- values restricts strings and integers to a set.
local SPECS = {
    -- File settings
    format = { kind = "string", values = oneOf("JPEG", "PNG", "TIFF", "PSD", "DNG", "ORIGINAL") },
    jpeg_quality = { kind = "number", min = 0, max = 1 },
    jpeg_useLimitSize = { kind = "boolean" },
    jpeg_limitSize = { kind = "integer", min = 1 },
    export_colorSpace = { kind = "string" },
    export_bitDepth = { kind = "integer", values = oneOf(8, 16) },
    tiff_compressionMethod = { kind = "string",
        values = oneOf("compressionMethod_None", "compressionMethod_LZW", "compressionMethod_ZIP") },
    tiff_preserveTransparency = { kind = "boolean" },
    DNG_compatibility = { kind = "integer", min = 0 },
    DNG_conversionMethod = { kind = "string" },
    DNG_previewSize = { kind = "string", values = oneOf("none", "medium", "large") },
    DNG_embedCache = { kind = "boolean" },
    DNG_embedRAW = { kind = "boolean" },
    DNG_lossyCompression = { kind = "boolean" },
    DNG_compressed = { kind = "boolean" },
    includeVideoFiles = { kind = "boolean" },

    -- Image sizing
    size_doConstrain = { kind = "boolean" },
    size_doNotEnlarge = { kind = "boolean" },
    size_resizeType = { kind = "string",
        values = oneOf("wh", "dimensions", "longEdge", "shortEdge", "megapixels", "percentage") },
    size_maxWidth = { kind = "number", min = 0, minExclusive = true },
    size_maxHeight = { kind = "number", min = 0, minExclusive = true },
    size_units = { kind = "string", values = oneOf("pixels", "inch", "cm") },
    size_megapixels = { kind = "number", min = 0, minExclusive = true },
    size_percentage = { kind = "number", min = 0, minExclusive = true },
    size_resolution = { kind = "number", min = 0, minExclusive = true },
    size_resolutionUnits = { kind = "string", values = oneOf("inch", "cm") },

    -- Output sharpening
    outputSharpeningOn = { kind = "boolean" },
    outputSharpeningMedia = { kind = "string", values = oneOf("screen", "matte", "glossy") },
    outputSharpeningLevel = { kind = "integer", values = oneOf(1, 2, 3) },

    -- Metadata
    embeddedMetadataOption = { kind = "string" },
    metadata_keywordOptions = { kind = "string" },
    removeLocationMetadata = { kind = "boolean" },
    removeFaceMetadata = { kind = "boolean" },
    includeFaceTagsAsKeywords = { kind = "boolean" },
    includeFaceTagsInIptc = { kind = "boolean" },

    -- File naming
    renamingTokensOn = { kind = "boolean" },
    tokens = { kind = "string" },
    tokenCustomString = { kind = "string", allowEmpty = true },
    initialSequenceNumber = { kind = "integer", min = 0 },
    extensionCase = { kind = "string", values = oneOf("lowercase", "uppercase") },

    -- Watermark
    useWatermark = { kind = "boolean" },
    watermarking_id = { kind = "string" },
}

ExportSettings.SPECS = SPECS

local function sortedKeys(values)
    local keys = {}
    for k in pairs(values) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    return table.concat(keys, ", ")
end

local function checkValue(key, value, spec)
    local name = "settings." .. key
    if spec.kind == "boolean" then
        if type(value) ~= "boolean" then error(name .. " must be true or false", 0) end
        return
    end
    if spec.kind == "string" then
        if type(value) ~= "string" then error(name .. " must be a string", 0) end
        if value == "" and not spec.allowEmpty then error(name .. " must not be empty", 0) end
        if value:find("[%z\1-\31]") then error(name .. " must not contain control characters", 0) end
        if spec.values and not spec.values[value] then
            error(name .. " must be one of: " .. sortedKeys(spec.values), 0)
        end
        return
    end
    -- number or integer
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        error(name .. " must be a number", 0)
    end
    if spec.kind == "integer" and value ~= math.floor(value) then
        error(name .. " must be a whole number", 0)
    end
    if spec.values and not spec.values[value] then
        error(name .. " must be one of: " .. sortedKeys(spec.values), 0)
    end
    if spec.min ~= nil and (value < spec.min or (spec.minExclusive and value == spec.min)) then
        error(name .. " must be " .. (spec.minExclusive and "above " or "at least ") .. spec.min, 0)
    end
    if spec.max ~= nil and value > spec.max then
        error(name .. " must be at most " .. spec.max, 0)
    end
end

-- Validates a `settings` argument. Returns a new table with LR_-prefixed keys,
-- or nil when settings is nil. Raises on the first problem; nothing is
-- written or exported before this passes.
function ExportSettings.validate(settings)
    if settings == nil then return nil end
    if type(settings) ~= "table" then error("settings must be an object", 0) end
    if #settings > 0 then error("settings must be an object, not an array", 0) end
    local keys = {}
    for key in pairs(settings) do
        if type(key) ~= "string" then error("settings keys must be strings", 0) end
        keys[#keys + 1] = key
    end
    if #keys == 0 then error("settings must contain at least one setting", 0) end
    table.sort(keys)
    local prefixed = {}
    for _, key in ipairs(keys) do
        local spec = SPECS[key]
        if not spec then
            local bare = key:match("^LR_(.+)$")
            if bare and SPECS[bare] then
                error("settings." .. key .. ": leave out the LR_ prefix (use " .. bare .. ")", 0)
            end
            error("settings has unknown or unsupported property \"" .. key .. "\"", 0)
        end
        checkValue(key, settings[key], spec)
        prefixed["LR_" .. key] = settings[key]
    end
    return prefixed
end

-- Arguments of export_photos that set the same thing as a key in settings.
ExportSettings.CONFLICTS = {
    format = { "format" },
    quality = { "jpeg_quality", "jpeg_useLimitSize", "jpeg_limitSize" },
    width = { "size_doConstrain", "size_resizeType", "size_maxWidth", "size_maxHeight", "size_units",
        "size_megapixels", "size_percentage", "size_doNotEnlarge" },
}
ExportSettings.CONFLICTS.height = ExportSettings.CONFLICTS.width

-- Refuses an argument that a settings key would contradict.
function ExportSettings.requireNoConflict(args)
    if type(args.settings) ~= "table" then return end
    for _, argument in ipairs({ "format", "quality", "width", "height" }) do
        if args[argument] ~= nil then
            for _, key in ipairs(ExportSettings.CONFLICTS[argument]) do
                if args.settings[key] ~= nil then
                    error("Pass " .. argument .. " or settings." .. key .. ", not both", 0)
                end
            end
        end
    end
end

return ExportSettings
