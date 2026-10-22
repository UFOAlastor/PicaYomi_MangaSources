return function(ctx)
    return ctx.require("contract").wrap(ctx,ctx.require("init"),{legacy_order=true,render=true})
end
