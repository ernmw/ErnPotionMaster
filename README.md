# ErnPotionMaster

OpenMW mod that makes potion brewing fun.

## Installing

Download the [latest version here](https://github.com/erinpentecost/ErnPotionMaster/archive/refs/heads/main.zip). The mod's Nexus page is [here](https://www.nexusmods.com/morrowind/mods/57315).

Extract to your `mods/` folder. In your `openmw.cfg` file, add these lines in the correct spots:

```ini
data="/wherevermymodsare/mods/ErnPotionMaster-main"
content=ErnPotionMaster.omwscripts
```

## Credits

- ping.mp3 by jolup123 -- https://freesound.org/s/668790/ -- License: Creative Commons 0
- cancel.wav by pierrecartoons1979 -- https://freesound.org/s/90119/ -- License: Attribution NonCommercial 3.0
- https://labs.mapbox.com/maki-icons/
- Virtual List by Greatness7 (MIT)
- PCP myui by Qlonever (MIT)
- https://tornadogames.itch.io/magic-sparksattacks-for-the-devs/devlog/823492/just-posted-an-awesome-new-free-pack-of-sprites-under-cc0 (CC0)
- https://screamingbrainstudios.itch.io/seamless-space-backgrounds (CC0)
- https://opengameart.org/content/hit-animation-frame-by-frame
- https://freesound.org/people/Fr%C3%A9d%C3%A9ricDubois/sounds/804920/ - metal high pitched boink by FrédéricDubois -- https://freesound.org/s/804920/ -- License: Attribution 4.0


### maybe...
- https://cassala.itch.io/bubble-sprites (CC0)
- https://ansimuz.itch.io/gothicvania-patreon-collection (CC0)
-


magick /home/ern/workspace/ErnPotionMaster/textures/ErnPotionMaster/frames/hit_003.png -flop /home/ern/workspace/ErnPotionMaster/textures/ErnPotionMaster/frames/hit_003.png


magick /home/ern/workspace/ErnPotionMaster/textures/ErnPotionMaster/frames/hit_left.png -define dds:mipmaps=0 -define dds:compression=dxt5 /home/ern/workspace/ErnPotionMaster/textures/ErnPotionMaster/frames/hit_left.dds


magick "/home/ern/workspace/ErnPotionMaster/textures/ErnPotionMaster/hit.dds" -crop 256x256 +repage "/home/ern/workspace/ErnPotionMaster/textures/ErnPotionMaster/hit_%03d.png"
