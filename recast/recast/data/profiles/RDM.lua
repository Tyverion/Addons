return {
    hide_spells = {
        -- Common spam: hide if you don't want bars for every cast
        ["Cure"]        = true,
        ["Cure II"]     = true,
        ["Cure III"]    = true,
        ["Cure IV"]     = true,
        ["Dia"]         = true,
        ["Dia II"]      = true,
        ["Dia III"]     = true,
        ["Bio"]         = true,
        ["Bio II"]      = true,
        ["Bio III"]     = true,

        -- Buffs you may or may not care about tracking
        ["Protect IV"]  = true,
        ["Protect V"]   = true,
        ["Shell IV"]    = true,
        ["Shell V"]     = true,
        ["Haste"]       = true,
        ["Haste II"]    = false,
        ["Refresh"]     = true,
        ["Phalanx"]     = false,  -- keep if you like seeing it
        ["Stoneskin"]   = false,

        -- Nuke spam
        ["Fire"]        = true,
        ["Blizzard"]    = true,
        ["Thunder"]     = true,
        ["Stone"]       = true,
        ["Aero"]        = true,
        ["Water"]       = true,
    },

    hide_ja = {
        -- RDM JA
        -- ["Convert"]     = false,
        -- ["Saboteur"]    = false,
        -- ["Spontaneity"] = false,
        -- ["Composure"]   = false,

        -- Hide if you don't want bars for them:
        ["Saboteur"]    = true,
        ["Spontaneity"] = true,
    },
}
