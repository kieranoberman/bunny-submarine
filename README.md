# Bunny's Flying Submarine

A number line game for primary school children: steer a rabbit in a flying submarine up into the sky
and down under the sea (negative numbers) by pressing + or − and a number.

- `index.html` is the whole game.
- `config.js` holds the leaderboard's Supabase address and publishable key (safe to be public).
- `supabase-setup.sql` sets up the leaderboard database. Paste it into the Supabase SQL Editor and run it.
- `.github/workflows/keepalive.yml` stops the free Supabase database pausing during quiet weeks.

Players choose a made-up bunny nickname (a title and a bunny name, such as Captain Big Ears) and their year group. No real names, emails or passwords are stored.
The leaderboard shows each player's best round of the week (points × level) and resets every Monday.

Made by Kieran Oberman, a parent and maths enthusiast.
