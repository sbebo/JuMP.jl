using Base.Meta

#addToExpression(ex::Number, c::Number) = ex + c

addToExpression(ex::Number, c::Number, x::Number) = ex + c*x

addToExpression(ex::Number, c::Number, x::Variable) = AffExpr([x],[c],ex)

addToExpression(ex::Number, c::Number, x::AffExpr) = addToExpression(c*x, 1.0, ex) # TODO

addToExpression(ex::Number, c::Variable, x::Variable) = QuadExpr([c],[x],[1.0],AffExpr())

addToExpression(ex::Number, c::AffExpr, x::AffExpr) = c*x + ex # TODO

function addToExpression(aff::AffExpr, c::Number, x::Number)
    aff.constant += c*x
    return aff
end

function addToExpression(aff::AffExpr,c::Number,x::Variable)
    push!(aff,convert(Float64,c),x)
    return aff
end

function addToExpression(aff::AffExpr,c::Variable,x::Variable)
    q = QuadExpr([c],[x],[1.0],aff)
    return q
end

function addToExpression(aff::AffExpr,c::Number,x::AffExpr)
    append!(aff.vars, x.vars)
    append!(aff.coeffs, c*x.coeffs)
    aff.constant += c*x.constant
    return aff
end

addToExpression(aff::AffExpr,x::AffExpr,c::Variable) = addToExpression(aff,c,x)
addToExpression(aff::AffExpr,c::Variable,x::AffExpr) = QuadExpr(fill(c,length(x.vars)),
                                                                x.vars,
                                                                x.coeffs,
                                                                addToExpression(aff,x.constant,c))

addToExpression(aff::AffExpr, c::Number, x::QuadExpr) = QuadExpr(copy(x.qvars1),
                                                                 copy(x.qvars2), 
                                                                 c*x.qcoeffs, 
                                                                 addToExpression(aff,c,x.aff))

addToExpression(ex::AffExpr, c::AffExpr, x::AffExpr) = c*x + ex # TODO

function addToExpression(quad::QuadExpr,c::Number,x::Variable)
    push!(quad.aff,convert(Float64,c),x)
    return quad
end

function addToExpression(quad::QuadExpr,c::Number,x::Number)
    (quad.aff.constant += c*x)
    return quad
end

function addToExpression(quad::QuadExpr,c::Variable,x::Variable)
    push!(quad.qvars1, x)
    push!(quad.qvars2, c)
    return quad
end

function addToExpression(quad::QuadExpr,c::Number,x::AffExpr)
    append!(quad.aff.vars, x.vars)
    append!(quad.aff.coeffs, c*x.coeffs)
    quad.aff.constant += c*x.constant
    return quad
end

addToExpression(quad::QuadExpr,x::AffExpr,c::Variable) = addToExpression(quad,c,x)
function addToExpression(quad::QuadExpr,c::Variable,x::AffExpr)
    append!(quad.qvars1, fill(c,length(x.vars)))
    append!(quad.qvars2, x.vars)
    append!(quad.qcoeffs, x.coeffs)
    addToExpression(quad.aff,x.constant,c)
    return quad
end

addToExpression(quad::QuadExpr,x::QuadExpr,c::Number) = addToExpression(quad,c,x)
function addToExpression(quad::QuadExpr,c::Number,x::QuadExpr)
    append!(quad.qvars1,x.qvars1)
    append!(quad.qvars2,x.qvars2)
    append!(quad.qcoeffs,c*x.qcoeffs)
    addToExpression(quad,c,x.aff)
    return quad
end

addToExpression(ex::QuadExpr, c::AffExpr, x::AffExpr) = c*x + ex # TODO

addToExpression(aff, c, x) = error("Cannot construct an affine expression with a term of type ($(typeof(c)))*($(typeof(x)))")

stagedfunction addToExpression_reorder(ex, args...)
    # how many of the multiplicands are variables?
    n_var = mapreduce(t -> (t == Variable || t == AffExpr), +, args)
    has_quad = mapreduce(t -> (t == QuadExpr), |, args)
    if n_var == 0 && !has_quad
        #println("No variables")
        return :(addToExpression(ex, 1.0, (*)(args...)))
    elseif n_var == 1 && !has_quad # linear
        #println("Linear")
        coef_expr = Expr(:call, :*)
        coef_idx = Int[]
        var_idx = 0
        for i in 1:length(args)
            if args[i] == Variable || args[i] == AffExpr
                var_idx = i
            else
                push!(coef_expr.args, :(args[$i]))
            end
        end
        return :(addToExpression(ex, $coef_expr, args[$var_idx]))
    else
        #println("Nonlinear")
        # fall back
        coef_expr = Expr(:call, :*, [:(args[$i]) for i in 1:(length(args)-1)]...)
        return :(addToExpression(ex, $coef_expr, args[$(length(args))]))
    end


end

function parseCurly(x::Expr, aff::Symbol, constantCoef)
    if !(x.args[1] == :sum || x.args[1] == :∑ || x.args[1] == :Σ) # allow either N-ARY SUMMATION or GREEK CAPITAL LETTER SIGMA
        error("Expected sum outside curly braces")
    end
    if length(x.args) < 3
        error("Need at least two arguments for sum")
    end

    # we have a filter condition
    if isexpr(x.args[2],:parameters)
        cond = x.args[2]
        if length(cond.args) != 1
            error("No commas after semicolon allowed in sum expression, use && for multiple conditions")
        end
        # generate inner loop code first and then wrap in for loops
        newaff, innercode = parseExpr(x.args[3], aff, constantCoef, aff)
        @assert aff == newaff
        code = quote
            if $(esc(cond.args[1]))
                $innercode
            end
        end
        for level in length(x.args):-1:4
            code = :(
            for $(esc(x.args[level].args[1])) in $(esc(x.args[level].args[2]))
                $code
            end)
        end
    else # no condition
        newaff, code = parseExpr(x.args[2], aff, constantCoef, aff)
        for level in length(x.args):-1:3
            code = :(
            for $(esc(x.args[level].args[1])) in $(esc(x.args[level].args[2]))
                $code
            end)
        end
        len = :len
        # precompute the number of elements to add
        # this is unncessary if we're just summing constants
        preblock = :($len += length($(esc(x.args[length(x.args)].args[2]))))
        for level in (length(x.args)-1):-1:3
            preblock = Expr(:for, esc(x.args[level]),preblock)
        end
        preblock = quote
            $len = 0
            $preblock
            if isa($aff,GenericAffExpr)
                sizehint($aff.vars,length($aff.vars)+$len)
                sizehint($aff.coeffs,length($aff.coeffs)+$len)
            elseif isa($aff,GenericQuadExpr)
                sizehint($aff.qvars1,length($aff.qvars1)+$len)
                sizehint($aff.qvars2,length($aff.qvars2)+$len)
                sizehint($aff.qcoeffs,length($aff.qcoeffs)+$len)
                sizehint($aff.aff.vars,length($aff.aff.vars)+$len)
                sizehint($aff.aff.coeffs,length($aff.aff.coeffs)+$len)
            end
        end
        code = :($preblock;$code)
    end

    
    return code
end

# output is assigned to newaff
function parseExpr(x, aff::Symbol, coefficients::Vector, newaff::Symbol=gensym())
    #@show x
    #@show coefficients
    if !isa(x,Expr)
        # at the lowest level
        callexpr = Expr(:call,:addToExpression_reorder,aff,esc(x),coefficients...)
        return newaff, :($newaff = $callexpr)
    else
        if x.head == :call && x.args[1] == :+
            b = Expr(:block)
            aff_ = aff
            for arg in x.args[2:(end-1)]
                aff_, code = parseExpr(arg, aff_, coefficients)
                push!(b.args, code)
            end
            newaff, code = parseExpr(x.args[end], aff_, coefficients, newaff)
            push!(b.args, code)
            return newaff, b
        elseif x.head == :call && x.args[1] == :-
            if length(x.args) == 2 # unary subtraction
                return parseExpr(x.args[2], aff, vcat(coefficients, -1.0), newaff)
            else # a - b - c ...
                b = Expr(:block)
                aff_, code = parseExpr(x.args[2], aff, coefficients)
                push!(b.args, code)
                for arg in x.args[3:(end-1)]
                    aff_,code = parseExpr(arg, aff_, vcat(coefficients, -1.0))
                    push!(b.args, code)
                end
                newaff,code = parseExpr(x.args[end], aff_, vcat(coefficients, -1.0), newaff)
                push!(b.args, code)
                return newaff, b
            end
        elseif x.head == :call && x.args[1] == :*
            # we might need to recurse on multiple arguments, e.g.,
            # (x+y)*(x+y)
            is_complex_expr(ex) = isa(ex,Expr) && !isexpr(ex,:ref)
            n_expr = mapreduce(is_complex_expr, +, x.args)
            if n_expr == 1 # special case, only recurse on one argument and don't create temporary objects
                coefficients = Any[c for c in coefficients]
                which_idx = 0
                for i in 2:length(x.args)
                    if is_complex_expr(x.args[i])
                        which_idx = i
                    else
                        push!(coefficients, esc(x.args[i]))
                    end
                end
                return parseExpr(x.args[which_idx], aff, coefficients, newaff)
            else
                blk = Expr(:block)
                for i in 2:length(x.args)
                    if is_complex_expr(x.args[i])
                        s = gensym()
                        newaff_, parsed = parseExpr(x.args[i], s, [1.0])
                        push!(blk.args, :($s = 0.0; $parsed))
                        x.args[i] = newaff_
                    else
                        x.args[i] = esc(x.args[i])
                    end
                end
                callexpr = Expr(:call,:addToExpression_reorder,aff,vcat(coefficients,x.args[2:end])...)
                push!(blk.args, :($newaff = $callexpr))
                return newaff, blk
            end
        elseif x.head == :call && x.args[1] == :/
            @assert length(x.args) == 3
            numerator = x.args[2]
            denom = x.args[3]
            return parseExpr(numerator, aff, vcat(coefficients,esc(:(1/$denom))),newaff)
        elseif x.head == :curly
            return newaff, :($(parseCurly(x,aff,coefficients)); $newaff = $aff)
        else # at lowest level?
            !isexpr(x,:comparison) || error("Unexpected comparison in expression $x") 
            callexpr = Expr(:call,:addToExpression_reorder,aff,esc(x),coefficients...)
            return newaff, :($newaff = $callexpr)
        end
    end
end

###############################################################################
# buildrefsets
# Unexported. Takes as input an object representing a name, associated index 
# sets, and conditions on those sets, for example 
# buildrefsets(:(x[i=1:3,[:red,:blue]],k=S; i+k <= 6))
# Used internally in macros to build JuMPContainers and constraints. Returns 
#       refcall:  Expr to reference a particular element, e.g. :(x[i,j,k])
#       idxvars:  Index names used in referencing, e.g.g {:i,:j,:k}
#       idxsets:  Index sets for indexing, e.g. {1:3, [:red,:blue], S}
#       idxpairs: Vector of IndexPair
function buildrefsets(c::Expr)
    isexpr(c,:ref) || error("Unrecognized name in construction macro; expected $(string(c)) to be of the form name[...]")
    idxvars = {}
    idxsets = {}
    idxpairs = IndexPair[]
    # Creating an indexed set of refs
    cname = c.args[1]
    refcall = Expr(:ref,esc(cname))
    for s in c.args[2:end]
        if isa(s,Expr) && (s.head == :(=) || s.head == :in)
            idxvar = s.args[1]
            idxset = esc(s.args[2])
            push!(idxpairs, IndexPair(s.args[1],s.args[2]))
        else
            idxvar = gensym()
            idxset = esc(s)
            push!(idxpairs, IndexPair(nothing,s))
        end
        push!(idxvars, idxvar)
        push!(idxsets, idxset)
        push!(refcall.args, esc(idxvar))
    end
    return refcall, idxvars, idxsets, idxpairs
end

buildrefsets(c::Symbol)  = (esc(c), {}, {}, IndexPair[])
buildrefsets(c::Nothing) = (gensym(), {}, {}, IndexPair[])

###############################################################################
# getloopedcode
# Unexported. Takes a bit of code and corresponding looping information and 
# returns that code nested in corresponding loops, along with preceding code
# to construct an appropriate container. Input is:
#       c: symbolic representation of name and appropriate indexing sets, if
#          any. E.g. :(myvar) or :(x[i=1:3,[:red,:blue]])
#       code: inner loop code kernel to be nested in the loops
#       condition: a boolean expression to be evaluated before each kernel.
#                  If none, pass :().
#       idxvars: As defined for buildrefsets
#       idxsets: As defined for buildrefsets
#       idxpairs: As defined for buildrefsets
#       sym: A symbol or expression containing the element type of the 
#            resulting container, e.g. :AffExpr or :Variable
function getloopedcode(c::Expr, code, condition, idxvars, idxsets, idxpairs, sym)
    varname = getname(c)
    hascond = (condition != :())

    if hascond
        code = quote
            $(esc(condition)) || continue
            $code
        end
    end

    for (idxvar, idxset) in zip(reverse(idxvars),reverse(idxsets))
        code = quote
            for $(esc(idxvar)) in $idxset
                $code
            end
        end
    end
    if hascond || hasdependentsets(idxvars,idxsets)
        # force a JuMPDict
        N = length(idxsets)
        clear_dependencies(i) = (isdependent(idxvars,idxsets[i],i) ? nothing : idxsets[i])
        mac = :($(esc(varname)) = JuMPDict{$(sym),$N}(Dict{NTuple{$N},$sym}(),
                                                        $(quot(varname)),
                                                        $(Expr(:tuple,map(clear_dependencies,1:N)...)),
                                                        $idxpairs,
                                                        :()))
    else 
        mac = Expr(:macrocall,symbol("@gendict"),esc(varname),sym,idxpairs,idxsets...)
    end
    return quote 
        $mac
        $code
        nothing
    end 
end

getloopedcode(c, code, condition, idxvars, idxsets, idxpairs, sym) = code

getname(c::Symbol) = c
getname(c::Nothing) = ()
getname(c::Expr) = c.args[1]

macro addConstraint(m, x, extra...)
    m = esc(m)
    # Two formats:
    # - @addConstraint(m, a*x <= 5)
    # - @addConstraint(m, myref[a=1:5], a*x <= 5)
    length(extra) > 1 && error("in @addConstraint: too many arguments.")
    # Canonicalize the arguments
    c = length(extra) == 1 ? x        : nothing
    x = length(extra) == 1 ? extra[1] : x

    (x.head != :comparison) &&
        error("in @addConstraint ($(string(x))): expected comparison operator (<=, >=, or ==).")

    # Strategy: build up the code for non-macro addconstraint, and if needed
    # we will wrap in loops to assign to the ConstraintRefs
    crefflag = isa(c,Expr)
    refcall, idxvars, idxsets, idxpairs = buildrefsets(c)
    # Build the constraint
    if length(x.args) == 3
        # Simple comparison - move everything to the LHS
        if !((x.args[2] == :<=) || (x.args[2] == :≤) ||
             (x.args[2] == :>=) || (x.args[2] == :≥) ||
             (x.args[2] == :(==)))
            error("in @addConstraint ($(string(x))): expected comparison operator (<=, >=, or ==).")
        end
        lhs = :($(x.args[1]) - $(x.args[3]))
        newaff, parsecode = parseExpr(lhs, :q, [1.0])
        code = quote
            q = AffExpr()
            $parsecode
            $crefflag && !isa(q,AffExpr) && error("Three argument form of @addConstraint does not currently support quadratic constraints")
            $(refcall) = addConstraint($m, $(x.args[2])($newaff,0))
        end
    elseif length(x.args) == 5
        # Ranged row
        if (x.args[2] != :<= && x.args[2] != :≤) || (x.args[4] != :<= && x.args[4] != :≤)
            error("in @addConstraint ($(string(x))): only ranged rows of the form lb <= expr <= ub are supported.")
        end
        lb = x.args[1]
        ub = x.args[5]
        newaff, parsecode = parseExpr(x.args[3],:aff, [1.0])
        code = quote
            aff = AffExpr()
            if !isa($(esc(lb)),Number)
                error(string("in @addConstraint (",$(string(x)),"): expected ",$(string(lb))," to be a number."))
            elseif !isa($(esc(ub)),Number)
                error(string("in @addConstraint (",$(string(x)),"): expected ",$(string(ub))," to be a number."))
            end
            $parsecode
            isa($newaff,AffExpr) || error("Ranged quadratic constraints are not allowed") 
            $(refcall) = addConstraint($m, LinearConstraint($newaff,$(esc(lb))-aff.constant,$(esc(ub))-aff.constant))
        end
    else
        # Unknown
        error("in @addConstraint ($(string(x))): constraints must be in one of the following forms:\n" *
              "       expr1 <= expr2\n" * "       expr1 >= expr2\n" *
              "       expr1 == expr2\n" * "       lb <= expr <= ub")
    end

    return getloopedcode(c, code, :(), idxvars, idxsets, idxpairs, :LinConstrRef)
end

macro addConstraints(m, x)
    x.head == :block || error("Invalid syntax for @addConstraints")
    @assert x.args[1].head == :line
    code = quote end
    for it in x.args
        if it.head == :line
            # do nothing
        elseif it.head == :comparison # regular constraint
            mac = Expr(:macrocall,symbol("@addConstraint"), esc(m), esc(it))
            code = quote
                    $code
                    $mac
                    end
        elseif it.head == :tuple # constraint ref
            mac = Expr(:macrocall,symbol("@addConstraint"), esc(m), esc(it.args[1]), esc(it.args[2]))
            code = quote
                    $code
                    $mac
                    end
        end
    end
    return quote 
            $code 
            nothing
            end
end

macro setObjective(m, args...)
    if length(args) != 2
        # Either just an objective sene, or just an expression.
        error("in @setObjective: needs three arguments: model, objective sense (Max or Min) and expression.")
    end
    sense, x = args
    if sense == :Min || sense == :Max
        sense = Expr(:quote,sense)
    end
    newaff, parsecode = parseExpr(x, :q, [1.0])
    quote
        q = AffExpr()
        $parsecode
        setObjective($(esc(m)), $(esc(sense)), $newaff)
    end
end

macro defExpr(args...)
    if length(args) == 1
        c = nothing
        x = args[1]
    elseif length(args) == 2
        c = args[1]
        x = args[2]
    else
        error("in @defExpr: needs either one or two arguments.")
    end

    crefflag = isa(c,Expr)
    refcall, idxvars, idxsets, idxpairs = buildrefsets(c)
    newaff, parsecode = parseExpr(x, :q, [1.0])
    code = quote
        q = AffExpr()
        $crefflag && !isa(q,AffExpr) && error("Three argument form of @defExpr does not currently support quadratic constraints")
        $parsecode
        $(refcall) = $newaff
    end
    
    return getloopedcode(c, code, :(), idxvars, idxsets, idxpairs, :AffExpr)
end

function hasdependentsets(idxvars, idxsets)
    # check if any index set depends on a previous index var
    for i in 2:length(idxsets)
        for v in idxvars[1:(i-1)]
            if dependson(idxsets[i],v)
                return true
            end
        end
    end
    return false
end

dependson(ex::Expr,s::Symbol) = any(a->dependson(a,s), ex.args)
dependson(ex::Symbol,s::Symbol) = (ex == s)
dependson(ex,s::Symbol) = false
function dependson(ex1,ex2)
    @assert isa(ex2, Expr)
    @assert ex2.head == :tuple
    any(s->dependson(ex1,s), ex2.args)
end

function isdependent(idxvars,idxset,i)
    for (it,idx) in enumerate(idxvars)
        it == i && continue
        dependson(idxset, idx) && return true
    end
    return false
end

macro defVar(args...)
    length(args) <= 1 &&
        error("in @defVar ($var): expected model as first argument, then variable information.")
    ######################################################################
    # # TODO: remove commented lines below when x[i,j;k,l] is valid syntax
    # if isa(args[1], Expr) && args[1].head == :parameters
    #     @assert length(args[1].args) == 1
    #     # push!(condition, args[1].args[1])
    #     condition = (args[1].args[1],)
    #     m = args[2]
    #     x = args[3]
    #     extra = args[4:end]
    # else
    #     m = args[1]
    #     x = args[2]
    #     extra = args[3:end]
    # end
    ######################################################################
    # ...and replace the following:
    condition = :()
    m = args[1]
    x = args[2]
    extra = args[3:end]
    ######################################################################
    m = esc(m)
    # Identify the variable bounds. Four (legal) possibilities are "x >= lb",
    # "x <= ub", "lb <= x <= ub", or just plain "x"
    if isexpr(x,:comparison)
        # We have some bounds
        if x.args[2] == :>= || x.args[2] == :≥
            if length(x.args) == 5
                # ub >= x >= lb
                x.args[4] == :>= || x.args[4] == :≥ || error("Invalid variable bounds")
                var = x.args[3]
                lb = esc(x.args[5])
                ub = esc(x.args[1])
            else
                # x >= lb
                var = x.args[1]
                @assert length(x.args) == 3
                lb = esc(x.args[3])
                ub = Inf
            end
        elseif x.args[2] == :<= || x.args[2] == :≤
            if length(x.args) == 5
                # lb <= x <= u
                var = x.args[3]
                (x.args[4] != :<= && x.args[4] != :≤) &&
                    error("in @defVar ($var): expected <= operator after variable name.")
                lb = esc(x.args[1])
                ub = esc(x.args[5])
            else
                # x <= ub
                var = x.args[1]
                # NB: May also be lb <= x, which we do not support
                #     We handle this later in the macro
                @assert length(x.args) == 3
                ub = esc(x.args[3])
                lb = -Inf
            end
        else
            # Its a comparsion, but not using <= ... <=
            error("in @defVar ($(string(x))): use the form lb <= ... <= ub.")
        end
    else
        # No bounds provided - free variable
        # If it isn't, e.g. something odd like f(x), we'll handle later
        var = x
        lb = -Inf
        ub = Inf
    end

    # Determine variable type (if present), as well as variables being 
    # added as complete columns. 
    # Types: default is continuous (reals), alternatives are Int and Bin.
    # ColGen: format is @defVar(..., [type], objcoef, constrrefs, values)
    t = :Cont
    gottype = 0
    if length(extra) > 0
        if extra[1] in [:Bin, :Int, :SemiCont, :SemiInt]
            gottype = 1
            t = extra[1]
        end

        if t == :Bin 
            if (lb != -Inf || ub != Inf) && !(lb == 0.0 && ub == 1.0)
            error("in @defVar ($var): bounds other than [0, 1] may not be specified for binary variables.\nThese are always taken to have a lower bound of 0 and upper bound of 1.")
            else
                lb = 0.0
                ub = 1.0
            end
        end

        # Handle the column generation functionality
        if length(extra) - gottype == 3
            !isa(var,Symbol) &&
                error("in @defVar ($var): can only create one variable at a time when adding to existing constraints.")

            objcoef = esc(extra[1+gottype])
            cols    = esc(extra[2+gottype])
            coeffs  = esc(extra[3+gottype])
            return quote
                $(esc(var)) = Variable($m,$lb,$ub,$(quot(t)),$objcoef,$cols,$coeffs,name=$(string(var)))
                nothing
            end
        end
        gottype == 0 &&
            error("in @defVar ($var): syntax error")
    end

    if isa(var,Symbol)
        # Easy case - a single variable
        return quote
            $(esc(var)) = Variable($m,$lb,$ub,$(quot(t)),$(string(var)))
        end
    end
    @assert isa(var,Expr)

    # We now build the code to generate the variables (and possibly the JuMPDict
    # to contain them)
    refcall, idxvars, idxsets, idxpairs = buildrefsets(var)
    code = :( $(refcall) = Variable($m, $lb, $ub, $(quot(t))) )
    looped = getloopedcode(var, code, condition, idxvars, idxsets, idxpairs, :Variable)
    varname = esc(getname(var))
    return quote 
        $looped
        push!($(m).dictList, $varname)
        $varname
    end
end

macro defConstrRef(var)
    if isa(var,Symbol)
        # easy case
        return esc(:(local $var))
    else
        if !isexpr(var,:ref)
            error("Syntax error: Expected $var to be of form var[...]")
        end
        
        varname = var.args[1]
        idxsets = var.args[2:end]
        idxpairs = IndexPair[]

        mac = Expr(:macrocall,symbol("@gendict"),varname,:ConstraintRef,idxpairs, idxsets...)
        code = quote 
            $(esc(mac))
            nothing
        end
        return code
    end
end

macro setNLObjective(m, sense, x)
    m = esc(m)
    if sense == :Min || sense == :Max
        sense = Expr(:quote,sense)
    end
    quote
        initNLP($m)
        setObjectiveSense($m, $(esc(sense)))
        ex = @processNLExpr($(esc(x)))
        $m.nlpdata.nlobj = ex
        $m.obj = QuadExpr()
    end
end 


macro addNLConstraint(m, x)
    m = esc(m)
    if (x.head != :comparison)
        error("Expected comparison operator in constraint $x")
    end
    if length(x.args) == 3 # simple comparison
        lhs = :($(x.args[1]) - $(x.args[3])) # move everything to the lhs
        id = hash(x)
        op = x.args[2]
        if op == :(==)
            lb = 0.0
            ub = 0.0
        elseif op == :(<=) || op == :(≤)
            lb = -Inf
            ub = 0.0
        else
            @assert op == :(>=) || op == :(≥)
            lb = 0.0
            ub = Inf
        end
        quote
            initNLP($m)
            c = NonlinearConstraint(@processNLExpr($(esc(lhs))), $lb, $ub)
            push!($m.nlpdata.nlconstr, c)
            push!($m.nlpdata.nlconstrlist, c.terms)
            nothing
        end
    else
        # ranged row
        error("Two-sided nonlinear constraints not yet supported")
    end
end
