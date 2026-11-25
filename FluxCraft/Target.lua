local _, FC = ...

-- The source folder is installed directly in the user's Retail AddOns tree and
-- may be mirrored to another installed client. Match both version and interface
-- from those installed clients; release packages instead pin one explicit target.
local version, _, _, interface = GetBuildInfo()
local triplet = type(version) == "string" and version:match("^(%d+%.%d+%.%d+)") or nil
local targets = {
    [16001] = { version = "1.60.1", flavor = "forever" },
    [50504] = { version = "5.5.4", flavor = "classic" },
    [20506] = { version = "2.5.6", flavor = "anniversary" },
    [11509] = { version = "1.15.9", flavor = "era" },
}
local match = targets[tonumber(interface)]
if match and triplet == match.version then
    FC.target = match.flavor
    FC.expectedInterface = tonumber(interface)
else
    FC.target = "unsupported"
    FC.disabled = true
end
