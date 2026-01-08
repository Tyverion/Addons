return {
    hide_spells = {
        -- Usually WANT to track:
        -- ["Foil"]         = false,
        -- ["Flash"]        = false,
        -- ["Valiance"]     = false,  -- JA, not spell; see hide_ja below
        -- ["Gambit"]       = false,  -- JA
        -- ["Liement"]      = false,  -- JA

        -- Hide generic utility if noisy
        ["Cure"]          = true,
        ["Cure II"]       = true,
        ["Cure III"]      = true,
        ["Protect"]       = true,
        ["Shell"]         = true,
        ["Barfire"]       = true,
        ["Barblizzard"]   = true,
        ["Barsleep"]      = true,
        -- etc.,
    },

    hide_ja = {
        -- Core: usually want
        -- ["Vallation"]   = false,
        -- ["Valiance"]    = false,
        -- ["Pflug"]       = false,
        -- ["Battuta"]     = false,
        -- ["Liement"]     = false,
        -- ["Gambit"]      = false,
        -- ["Rayke"]       = false,

        -- Optional hides
        ["Last Resort"]   = true,  -- if sub DRK and you don't care
        ["Swordplay"]     = false, -- change if you don't want it
    },
}
