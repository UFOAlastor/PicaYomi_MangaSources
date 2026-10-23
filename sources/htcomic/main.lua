return function(ctx)
    local source = ctx.require("contract").wrap(ctx,ctx.require("init"),{legacy_order=true,single_chapter_identity=true})
    local headers = ctx.require("headers")
    local get_image_request = source.getImageRequest
    function source:getImageRequest(resource, ...)
        -- Old history/cache entries may still contain the malformed address.
        -- Repair it at dispatch too, without rewriting the caller's record.
        local normalized = {}
        for key, value in pairs(resource) do normalized[key] = value end
        normalized.url = headers:normalizeImageUrl(resource.url)
        return get_image_request(self, normalized, ...)
    end
    return source
end
