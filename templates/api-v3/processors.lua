local ctx=assert(ctx)
local P={}
function P.bands(image,context)
    return ctx.images.reorderBands(image,context.bands)
end
function P.base64(file)
    return ctx.images.writeFile(file,assert(ctx.b64.decode(ctx.images.readFile(file))))
end
return P
