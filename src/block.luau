--!strict
-- The `prguide.guide` block: a thin shell that mounts a review page (src/review-page.luau) at the "main" region.
local ReviewPage = require("./review-page")

local ROOT = "main"

local block: BlockDef<ReviewPage.ReviewPage> = {
 init = function(cx: BlockCx, args: { string }): ReviewPage.ReviewPage return ReviewPage.init(cx, args, ROOT) end,
 title = ReviewPage.title,
 view = ReviewPage.view,
 event = ReviewPage.event,
 key = ReviewPage.key,
}

return block
