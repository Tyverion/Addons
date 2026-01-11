FastCS   - I've adjusted this to only enable post menu selection. So we're not trying to select a menu option at a billion fps.

rnpc     - This is a multibox tool that when loaded on all of your characters. 
          And if any of your characters can't see an entity find one that can and use //rnpc while targeting the entity (i.e. Maws). 
          This will force the NPC update request.
      
muffins  - Tracks gained muffins for a sortie run.

Debuffed - Added several debuff tracking.
          Debuffed will track multiple targets and identify them as "Vampire Leech A" "Vampire Leech B" etc. Up to 15.
          By default I have the setting "trusted" enabled. 
          This will enable a party chat when a debuff drops from the above mob identifier and 
          remove that debuff from anyone else that has this version of debuffed loaded.
          You only get a list of active debuffs on the mob you're currently targeting unless you use the command 
		  
         	//db watch "leech a"
          	//db watch "ongo" 

Recast   - This is basically timers but draggable and if you are a multiboxer you can track your other char's cooldowns.
		  [Recast] Commands:
		  
		  //recast style up|down                 - stack direction
		  //recast sizeh small|mid|large         - bar height presets
		  //recast sizew <80-400>                - bar width
		  //recast stacked on|off                - share local/remote column
		  //recast watch add|remove <name>       - track another character              
		  //recast watch list                    - list watched characters              
		  //recast ja add|remove <name>          - track/untrack a JA group              
		  //recast ja list                       - list tracked JA groups              
		  //recast color list                    - show remote colors              
		  //recast color <name|default> r g b    - set remote bar color              
		  //recast profile blacklist|whitelist   - save per-job filter profile

CVM     - //cvm run <= 6 yalms from curior moogle.

		- Below is a sort of default buy list.

		return {
		
   	 wanted = {
	
	        -- Medicine (opt=1)
	        ['Panacea']        = { qty = 24,  slot = 11, opt = 1 },
	        ['Echo Drops']     = { qty = 12,  slot = 13, opt = 1 },
	        ['Antacid']        = { qty = 12,  slot = 14, opt = 1 },
	        ['Holy Water']     = { qty = 12,  slot = 15, opt = 1 },
	        ['Remedy']         = { qty = 12,  slot = 16, opt = 1 },
	        ['Prism Powder']   = { qty = 12,  slot = 18, opt = 1 },
	        ['Silent Oil']     = { qty = 12,  slot = 19, opt = 1 },
	        ['Reraiser']       = { qty = 1,   slot = 21, opt = 1 },
	        ['Hi-Reraiser']    = { qty = 1,   slot = 22, opt = 1 },
	        ['Vile Elixir']    = { qty = 1,   slot = 23, opt = 1 },
	        ['Vile Elixir +1'] = { qty = 1,   slot = 24, opt = 1 },
	
	        -- Foodstuffs
	        ['Grape Daifuku']  = { qty = 12, slot = 67, opt = 4 },
	    }
	}
