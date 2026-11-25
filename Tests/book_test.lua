local ns = {}
assert(loadfile("FluxCraft/Book.lua"))("FluxLogistics", ns)

local entries = ns.BookMixin.BuildEntries({
    {id = 101, name = "Tailoring", rank = 75, maxRank = 150},
    {id = 202, name = "Alchemy", rank = 20, maxRank = 75},
}, {
    characterKey = "current",
    recipesById = {
        a = {id = "a", professionId = 101, characterKey = "current", learned = true},
        b = {id = "b", professionId = 101, characterKey = "current", learned = true},
        alt = {id = "alt", professionId = 202, characterKey = "other", learned = true},
    },
    unobservedProfessions = {
        {id = 202, message = "Open Alchemy to discover its recipes."},
    },
})

assert(#entries == 2)
assert(entries[1].recipeCount == 2 and entries[1].discoveryPrompt == nil)
assert(entries[2].recipeCount == 0)
assert(entries[2].discoveryPrompt == "Open Alchemy to discover its recipes.")
print("book recipe-memory fixtures passed")
