# REAPER Guitar Pro Import

Imports Guitar Pro 7 and Guitar Pro 8 files (.gp) directly into REAPER as multitrack MIDI.

## Features

- GP7 support
- GP8 support
- Multiple tracks
- Tempo changes
- Time signatures
- Drum tracks
- Ties
- Dynamics

## Requirements

- REAPER
- Windows (including PowerShell)

## Installation

1. Download the Lua script.
2. Open REAPER.
3. Actions → Show Action List.
4. ReaScript → Load.
5. Select the Lua file.

## Usage

Run the script and select a .gp file.

The script creates a temporary MIDI file and imports it into REAPER.

## Limitations

- Imports MIDI only
- Conversion of articulations not fully tested
- Currently works in Windows only

## Compatibility

Compatible with Guitar Pro 7 and Guitar Pro 8 files
