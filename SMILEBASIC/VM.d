module otya.smilebasic.vm;
import otya.smilebasic.type;
import otya.smilebasic.token;
import otya.smilebasic.error;
import otya.smilebasic.compiler;
import otya.smilebasic.petitcomputer;
import otya.smilebasic.systemvariable;
import std.uni;
import std.utf;
import std.conv;
import std.stdio;
struct VMVariable
{
    int index;
    ValueType type;
    this(int index, ValueType type)
    {
        this.index = index;
        this.type = type;
    }
    this(int index)
    {
        this.index = index;
    }
}
class VMSlot
{
    bool isUsed;
    DataTable globalDataTable;
    //2MBらしい
    //Code code[2 * 1024 * 1024 / Code.sizeof];
    Code[] code;
    SourceLocation[] location;
    Value[] global;
    VMVariable[wstring] globalTable;
    Function[wstring] functions;
    Function[] functionTable;
    int[wstring] globalLabel;
    DebugInfo debugInfo;
    Value[wstring] directModeVariable;
}
class VM
{
    VMSlot[5] slots;
    Function[wstring] commonFunctions;
    int slot;
    VMSlot currentSlot;
    int stacki;
    int pc;
    Value[] stack;
    int bp;
    PetitComputer petitcomputer;
    this()
    {
        this.stack = new Value[16384];
        for(int i = 0; i < slots.length; i++)
        {
            slots[i] = new VMSlot();
        }
    }
    int currentSlotNumber()
    {
        return slot;
    }
    void setCurrentSlot(int slot)
    {
        currentSlot = slots[slot];
        this.slot = slot;
    }
    void directSlot(sizediff_t start, Code[] code, int len, VMVariable[wstring] globalTable, Function[wstring] functions, DataTable gdt/*GNU Debugging Tools*/,
                    int[wstring] globalLabel, DebugInfo dinfo)
    {
        this.pc = cast(int)start;
        auto c = this.currentSlot;
        c.globalTable = globalTable;
        c.code = code;
        sizediff_t oldlen = c.global.length;
        sizediff_t addedvarcount = len - oldlen;
        for(sizediff_t i = 0; i < addedvarcount; i++)
            c.global ~= Value(ValueType.Void);
        foreach(wstring k, VMVariable v ; globalTable)
        {
            if(v.index >= 0 && v.index >= oldlen && v.index < c.global.length)
                c.global[v.index] = Value(v.type);
        }
    }
    void loadSlot(int slot, Code[] code, int len, VMVariable[wstring] globalTable, Function[wstring] functions, DataTable gdt/*GNU Debugging Tools*/,
         int[wstring] globalLabel, DebugInfo dinfo)
    {
        auto s = this.slots[slot];
        s.isUsed = true;
        s.code = code;
        s.global = new Value[len];
        s.globalTable = globalTable;
        foreach(wstring k, VMVariable v ; globalTable)
        {
            if(v.index >= 0)
                s.global[v.index] = Value(v.type);
        }
        s.functions = functions;
        s.globalDataTable = gdt;
        s.globalLabel = globalLabel;
        s.debugInfo = dinfo;
    }
    Code getCurrent()
    {
        return currentSlot.code[pc];
    }
    void run()
    {
        bp = 0;//globalを実行なのでbaseは0(グローバル変数をスタックに取るようにしない限り)(挙動的にスタックに確保していなさそう)
        for(pc = 0; pc < this.currentSlot.code.length; pc++)
        {
            processBreakPoint;
            currentSlot.code[pc].execute(this);
        }
        if(stacki != 0)
        {
            stderr.writeln("CompilerBug?:stack");
        }
    }
    SourceLocation currentLocation()
    {
        return currentSlot.debugInfo.getLocationByAddress(pc);
    }
    void init(PetitComputer petitcomputer)
    {
        this.petitcomputer = petitcomputer;
        bp = 0;//globalを実行なのでbaseは0(グローバル変数をスタックに取るようにしない限り)(挙動的にスタックに確保していなさそう)
    }
    void processBreakPoint()
    {
        if (currentSlot.debugInfo.location.length > pc && currentSlot.debugInfo.location[pc].isBreakPoint)
        {
            //TODO:まともにする
            writefln("break point\nslot:%d,pc:%d,line:%d", currentSlotNumber, pc, currentSlot.debugInfo.location[pc].location.line);
            readln();
        }
    }
    bool runStep()
    {
        if(pc < this.currentSlot.code.length)
        {
            processBreakPoint;
            currentSlot.code[pc].execute(this);
            pc++;
            return true;
        }
        return false;
    }
    void poppc()
    {
        Value value;
        pop(value);
        if(value.type == ValueType.InternalAddress)
        {
            pc = value.integerValue;
            return;
        }
        if(value.type == ValueType.InternalSlotAddress)
        {
            pc = value.internalAddress.address;
            setCurrentSlot(value.internalAddress.slot);
            return;
        }
        assert(false, "internal error, compiler bug?");
    }
    void pushpc()
    {
        Value value;
        value.type = ValueType.InternalAddress;
        value.integerValue = pc;
        push(value);
    }
    void push(ref Value value)
    {
        if(stacki >= this.stack.length)
        {
            writeln("Stack OF");
            readln();
        }
        stack[stacki++] = value;
    }
    void push(Value value)
    {
        stack[stacki++] = value;
    }
    bool canPop()
    {
        return stacki > bp;
    }
    void pop(out Value value)
    {
        if(stacki <= bp)
        {
            writeln("Stack underflow");
            readln();
        }
        value = stack[--stacki];
    }
    void decSP()
    {
        if(stacki <= bp)
        {
            writeln("Stack underflow");
            readln();
        }
        --stacki;
    }
    Value testGetGlobalVariable(wstring name)
    {
        return currentSlot.global[currentSlot.globalTable[name].index];
    }
    void end()
    {
        pc = cast(int)currentSlot.code.length;
    }
    void dump()
    {
        foreach(i, c; currentSlot.code)
            writefln("%04X:%s", i, c.toString(this));
    }
    wstring getGlobalVarName(int index)
    {
        foreach(k, v; currentSlot.globalTable)
        {
            if(v.index == index) return k;
        }
        return "undefined variable";
    }
    Value readData()
    {
        Value value;
        this.currentSlot.globalDataTable.read(value, this);
        return value;
    }
    void restoreData(wstring label)
    {
        this.currentSlot.globalDataTable.dataIndex = this.currentSlot.globalDataTable.label[label];
    }
    int olddti;
    void pushDataIndex()
    {
        olddti = this.currentSlot.globalDataTable.dataIndex;
    }
    void popDataIndex()
    {
       this.currentSlot.globalDataTable.dataIndex = olddti;
    }
}
enum CodeType
{
    Push,
    PushG,
    PushL,
    Operate,
    Return,
    Goto,
    Gosub,
    Print,
    PopG,
    PopL,
    GotoS,
    GotoFalse,
    GotoTrue,
    GosubS,
    ReturnSubroutine,
    OnS,
    RestoreCodeS,
}
abstract class Code
{
    CodeType type;
    abstract void execute(VM vm);
    string toString(VM vm)
    {
        return super.toString();
    }
}
class PrintCode : Code
{
    int count;
    this(int count)
    {
        this.type = CodeType.Print;
        this.count = count;
    }
    override void execute(VM vm)
    {
        for(int i = 0;i < count; i++)
        {
            Value arg;
            vm.pop(arg);
            switch(arg.type)
            {
                case ValueType.Integer:
                    //write(arg.integerValue);
                    if(vm.petitcomputer)
                        vm.petitcomputer.console.print(arg.integerValue);
                    break;
                case ValueType.Double:
                    //write(arg.doubleValue);
                    if(vm.petitcomputer)
                        vm.petitcomputer.console.print(arg.doubleValue);
                    break;
                case ValueType.String:
                    //write(arg.stringValue);
                    if(vm.petitcomputer)
                        vm.petitcomputer.console.printString(arg.stringValue);
                    break;
                default:
                    //type mismatch
                    throw new TypeMismatch();
            }
        }
        stdout.flush();
    }
    override string toString(VM vm)
    {
        return "print";
    }
}
/*
* スタックにPush
*/
class Push : Code
{
    Value imm;
    this(Value imm)
    {
        this.type = CodeType.Push;
        this.imm = imm;
    }
    override void execute(VM vm)
    {
        vm.push(imm);
    }
    override string toString(VM vm)
    {
        return "push " ~ imm.toString;
    }
}

class PushG : Code
{
    int var;
    this(int var)
    {
        this.type = CodeType.PushG;
        this.var = var;
    }
    override void execute(VM vm)
    {
        vm.push(vm.currentSlot.global[var]);
    }
    override string toString(VM vm)
    {
        return "pushglobal " ~ vm.getGlobalVarName(var).to!string;
    }
}
class PushGRef : Code
{
    int var;
    this(int var)
    {
        this.var = var;
    }
    override void execute(VM vm)
    {
        vm.push(Value(&vm.currentSlot.global[var]));
    }
    override string toString(VM vm)
    {
        return "pushglobalref " ~ vm.getGlobalVarName(var).to!string;
    }
}
class PopG : Code
{
    int var;
    this(int var)
    {
        this.type = CodeType.PopG;
        this.var = var;
    }
    override void execute(VM vm)
    {
        Value v;
        Value g = vm.currentSlot.global[var];
        vm.pop(v);
        if(v.type == ValueType.Integer && g.type == ValueType.Double)
        {
            vm.currentSlot.global[var] = Value(cast(double)v.integerValue);
            return;
        }
        if(g.type == ValueType.Integer && v.type == ValueType.Double)
        {
            vm.currentSlot.global[var] = Value(cast(int)v.doubleValue);
            return;
        }
        if(g.type == ValueType.Void)
        {
            vm.currentSlot.global[var] = v;
            return;
        }
        if(v.type != g.type)
        {
            throw new TypeMismatch();
        }
        vm.currentSlot.global[var] = v;
    }
    override string toString(VM vm)
    {
        return "popglobal " ~ vm.getGlobalVarName(var).to!string;
    }
}
class PushL : Code
{
    int var;
    this(int var)
    {
        this.type = CodeType.PushL;
        this.var = var;
    }
    override void execute(VM vm)
    {
        vm.push(vm.stack[vm.bp + var]);
    }
    override string toString(VM vm)
    {
        return "pushlocal " ~ var.to!string;
    }
}
class PushLRef : Code
{
    int var;
    this(int var)
    {
        this.var = var;
    }
    override void execute(VM vm)
    {
        vm.push(Value(&vm.stack[vm.bp + var]));
    }
    override string toString(VM vm)
    {
        return "pushlocalref " ~ var.to!string;
    }
}
class PopL : Code
{
    int var;
    this(int var)
    {
        this.type = CodeType.PopL;
        this.var = var;
    }
    override void execute(VM vm)
    {
        Value v;
        Value g = vm.stack[vm.bp + var];
        vm.pop(v);
        if(v.type == ValueType.Integer && g.type == ValueType.Double)
        {
            vm.stack[vm.bp + var] = Value(cast(double)v.integerValue);
            return;
        }
        if(g.type == ValueType.Integer && v.type == ValueType.Double)
        {
            vm.stack[vm.bp + var] = Value(cast(int)v.doubleValue);
            return;
        }
        if(g.type == ValueType.Void)
        {
            vm.stack[vm.bp + var] = v;
            return;
        }
        if(v.type != g.type)
        {
            throw new TypeMismatch();
        }
        vm.stack[vm.bp + var] = v;
    }
    override string toString(VM vm)
    {
        return "poplocal " ~ var.to!string;
    }
}
class Operate : Code
{
    TokenType operator;
    this(TokenType op)
    {
        this.operator = op;
    }

    override void execute(VM vm)
    {
        Value l;
        Value r;
        vm.pop(r);
        int ri = r.integerValue;
        double rd = r.integerValue;
        bool numf = r.type == ValueType.Double || r.type == ValueType.Integer; 
        if(r.type == ValueType.Double)
        {
            ri = cast(int)r.doubleValue;
            rd = r.doubleValue;
        }
        switch(operator)
        {
            //単項演算子
            case TokenType.Not:
                if(numf)
                    vm.push(Value(~ri));
                else
                    throw new TypeMismatch();
                return;
            case TokenType.LogicalNot:
                if(numf)
                    vm.push(Value(!ri));
                else
                    throw new TypeMismatch();
                return;
            default:
                break;
        }
        vm.pop(l);
        if(l.type == ValueType.IntegerArray)
            //l.type == ValueType.StringArray || l.type == ValueType.DoubleArray)
        {
            if(operator != TokenType.LBracket)
            {
                throw new TypeMismatch();
            }
            vm.push(Value(l.integerArray[ri]));
            return;
        }
        if(l.type == ValueType.String)
        {
            wstring ls = l.stringValue;
            if(r.type == ValueType.String)
            {
                wstring rs = r.stringValue;
                switch(operator)
                {
                    case TokenType.Plus:
                        vm.push(Value(ls ~ rs));
                        return;
                    case TokenType.Equal:
                        vm.push(Value(ls == rs));
                        return;
                    case TokenType.NotEqual:
                        vm.push(Value(ls != rs));
                        return;
                    case TokenType.Less:
                        vm.push(Value(ls < rs));
                        return;
                    case TokenType.LessEqual:
                        vm.push(Value(ls <= rs));
                        return;
                    case TokenType.Greater:
                        vm.push(Value(ls > rs));
                        return;
                    case TokenType.GreaterEqual:
                        vm.push(Value(ls >= rs));
                        return;
                    default:
                        //type mismatch
                        throw new TypeMismatch();
                }
            }
            if(r.type == ValueType.Integer || r.type == ValueType.Double)
            {
                switch(operator)
                {
                    //数値 * 文字列だとエラー
                    case TokenType.Mul:
                        {
                            //wstring delegate(wstring, wstring, int) mul;
                            //mul = (x, y, z) => z > 0 ? x ~ mul(x , y, z - 1) : "";
                            //vm.push(Value(mul(ls, ls, cast(int)rd)));
                            import std.array : replicate;
                            vm.push(Value(replicate(ls, cast(int)rd)));
                        }
                        return;
                    //3.1から?文字列と数値を比較すると3を返す
                    //(数値 compare 文字列だとエラー)
                    case TokenType.Equal:
                    case TokenType.NotEqual:
                    case TokenType.Less:
                    case TokenType.LessEqual:
                    case TokenType.Greater:
                    case TokenType.GreaterEqual:
                        vm.push(Value(3));
                        return;
                    case TokenType.LBracket:
                        vm.push(Value(ls[ri].to!wstring));
                        return;
                    default:
                        //type mismatch
                        throw new TypeMismatch();
                }
            }
        }
        int li = l.integerValue;
        if (l.isInteger && r.isInteger)
        {
            switch(operator)
            {
                case TokenType.Plus:
                    vm.push(Value(li + ri));
                    return;
                case TokenType.Minus:
                    vm.push(Value(li - ri));
                    return;
                case TokenType.Mul:
                    vm.push(Value(li * ri));
                    return;
                case TokenType.Div:
                    vm.push(Value(li / ri));
                    return;
                case TokenType.IntDiv:
                    //TODO:範囲外だとOverflow
                    vm.push(Value(cast(int)(li / ri)));
                    return;
                case TokenType.Mod:
                    vm.push(Value(li % ri));
                    return;
                case TokenType.And:
                    vm.push(Value(li & ri));
                    return;
                case TokenType.Or:
                    vm.push(Value(li | ri));
                    return;
                case TokenType.LogicalAnd:
                    vm.push(Value(li && ri));
                    return;
                case TokenType.LogicalOr:
                    vm.push(Value(li || ri));
                    return;
                case TokenType.Xor:
                    vm.push(Value(li ^ ri));
                    return;
                case TokenType.Equal:
                    vm.push(Value(li == ri));
                    return;
                case TokenType.NotEqual:
                    vm.push(Value(li != ri));
                    return;
                case TokenType.Less:
                    vm.push(Value(li < ri));
                    return;
                case TokenType.LessEqual:
                    vm.push(Value(li <= ri));
                    return;
                case TokenType.Greater:
                    vm.push(Value(li > ri));
                    return;
                case TokenType.GreaterEqual:
                    vm.push(Value(li >= ri));
                    return;
                case TokenType.LeftShift:
                    vm.push(Value(li << ri));
                    return;
                case TokenType.RightShift:
                    vm.push(Value(li >> ri));
                    return;
                default:
            }
        }

        if (!l.isNumber || !r.isNumber)
            throw new TypeMismatch();
        double ld;
        if(l.type == ValueType.Double)
        {
            li = cast(int)l.doubleValue;
            ld = l.doubleValue;
        }
        else
        {
            ld = l.integerValue;
        }
        //とりあえずInteger
        switch(operator)
        {
            case TokenType.Plus:
                ld += rd;
                break;
            case TokenType.Minus:
                ld -= rd;
                break;
            case TokenType.Mul:
                ld *= rd;
                break;
            case TokenType.Div:
                ld /= rd;
                break;
            case TokenType.IntDiv:
                //TODO:範囲外だとOverflow
                vm.push(Value(cast(int)(ld / rd)));
                return;
            case TokenType.Mod:
                ld %= rd;
                break;
            case TokenType.And:
                vm.push(Value(li & ri));
                return;
            case TokenType.Or:
                vm.push(Value(li | ri));
                return;
            case TokenType.LogicalAnd:
                vm.push(Value(li && ri));
                return;
            case TokenType.LogicalOr:
                vm.push(Value(li || ri));
                return;
            case TokenType.Xor:
                vm.push(Value(li ^ ri));
                return;
            case TokenType.Equal:
                vm.push(Value(ld == rd));
                return;
            case TokenType.NotEqual:
                vm.push(Value(ld != rd));
                return;
            case TokenType.Less:
                vm.push(Value(ld < rd));
                return;
            case TokenType.LessEqual:
                vm.push(Value(ld <= rd));
                return;
            case TokenType.Greater:
                vm.push(Value(ld > rd));
                return;
            case TokenType.GreaterEqual:
                vm.push(Value(ld >= rd));
                return;
            case TokenType.LeftShift:
                vm.push(Value(li << ri));
                return;
            case TokenType.RightShift:
                vm.push(Value(li >> ri));
                return;
            default:
                writeln("NotImpl: ", operator);
                break;
        }
        l.type = ValueType.Double;
        l.doubleValue = ld;
        vm.push(l);
    }
    override string toString(VM vm)
    {
        return "operate " ~ operator.to!string;
    }
}
class GotoAddr : Code
{
    int address;
    this(int addr)
    {
        this.type = CodeType.Goto;
        address = addr;
    }
    override void execute(VM vm)
    {
        vm.pc = address - 1;
    }
    override string toString(VM vm)
    {
        return "goto " ~ address.to!string(16);
    }
}
class GotoS : Code
{
    wstring label;
    Scope sc;
    this(wstring label, Scope sc)
    {
        this.type = CodeType.GotoS;
        this.label = label;
        this.sc = sc;
    }
    override void execute(VM vm)
    {
        stderr.writeln("can't execute (compiler bug?)");
    }
}
class GotoTrue : Code
{
    int address;
    this(int addr)
    {
        this.type = CodeType.GotoTrue;
        address = addr;
    }
    override void execute(VM vm)
    {
        Value cond;
        vm.pop(cond);
        if(cond.boolValue)
            vm.pc = address - 1;
    }
    override string toString(VM vm)
    {
        return "gototrue " ~ address.to!string(16);
    }
}
class GotoFalse : Code
{
    int address;
    this(int addr)
    {
        this.type = CodeType.GotoFalse;
        address = addr;
    }
    override void execute(VM vm)
    {
        Value cond;
        vm.pop(cond);
        if(!cond.boolValue)
            vm.pc = address - 1;
    }
    override string toString(VM vm)
    {
        return "gotofalse " ~ address.to!string(16);
    }
}
class GotoExpr : Code
{
    Scope sc;
    this(Scope sc)
    {
        this.sc = sc;
    }
    override void execute(VM vm)
    {
        Value label;
        vm.pop(label);
        if(!label.isString)
        {
            vm.pc = vm.currentSlot.globalLabel[label.castString] - 1;
        }
        else
        {
            throw new TypeMismatch();
        }
    }
}
class GosubAddr : Code
{
    int address;
    this(int addr)
    {
        this.type = CodeType.Gosub;
        address = addr;
    }
    override void execute(VM vm)
    {
        vm.pushpc;//vm.push(Value(vm.pc));
        vm.pc = address - 1;
    }
    override string toString(VM vm)
    {
        return "gosub " ~ address.to!string(16);
    }
}
class GosubS : Code
{
    wstring label;
    Scope sc;
    this(wstring label, Scope sc)
    {
        this.type = CodeType.GosubS;
        this.label = label;
        this.sc = sc;
    }
    override void execute(VM vm)
    {
        stderr.writeln("can't execute (compiler bug?)");
    }
}
class GosubExpr : Code
{
    Scope sc;
    this(Scope sc)
    {
        this.sc = sc;
    }
    override void execute(VM vm)
    {
        Value label;
        vm.pop(label);
        if(label.isString)
        {
            vm.pushpc;//vm.push(Value(vm.pc));
            vm.pc = vm.currentSlot.globalLabel[label.castString] - 1;
        }
        else
        {
            throw new TypeMismatch();
        }
    }
}
class ReturnSubroutine : Code
{
    this()
    {
        this.type = CodeType.ReturnSubroutine;
    }
    override void execute(VM vm)
    {
        Value pc;
        if(!vm.canPop())
        {
            throw new ReturnWithoutGosub();
        }
        /*vm.pop(pc);
        if(pc.type != ValueType.Integer || pc.integerValue < 0 || pc.integerValue >= vm.currentSlot.code.length)
        {
            stderr.writeln("Internal error:Compiler bug?");
            readln();
            return;
        }
        vm.pc = pc.integerValue;
        */
        vm.poppc;
    }
    override string toString(VM vm)
    {
        return "returnsubroutine ";
    }
}
class EndVM : Code
{
    this()
    {
    }
    override void execute(VM vm)
    {
        vm.end();
    }
    override string toString(VM vm)
    {
        return "endvm";
    }
}
class NewArray : Code
{
    ValueType type;
    int size;
    int[] dim;
    this(ValueType type, int size)
    {
        dim = new int[size];
        this.size = size;
        this.type = type;
    }
    override void execute(VM vm)
    {
        for(int i = size - 1; i >= 0; i--)
        {
            Value v;
            vm.pop(v);
            if(v.type == ValueType.Double)
            {
                dim[i] = cast(int)v.doubleValue;
                continue;
            }
            if(v.type == ValueType.Integer)
            {
                dim[i] = v.integerValue;
                continue;
            }
            throw new TypeMismatch();
        }
        Value array;
        switch(type)
        {
            case ValueType.Integer:
                array.type = ValueType.IntegerArray;
                array.integerArray = new Array!int(dim);
                break;
            case ValueType.Double:
                array.type = ValueType.DoubleArray;
                array.doubleArray = new Array!double(dim);
                break;
            case ValueType.String:
                array.type = ValueType.StringArray;
                array.stringArray = new Array!wstring(dim);
                break;
            default:
                throw new TypeMismatch();
        }
        vm.push(array);
    }
    override string toString(VM vm)
    {
        return "newarray " ~ dim.to!string;
    }
}
class PushArray : Code
{
    int dim;
    this(int dim)
    {
        this.dim = dim;
    }
    override void execute(VM vm)
    {
        int[4] index;
        for(int i = 0; i < dim; i++)
        {
            Value v;
            vm.pop(v);
            if(v.type == ValueType.Integer)
            {
                index[i] = v.integerValue;
                continue;
            }
            if(v.type == ValueType.Double)
            {
                index[i] = cast(int)v.doubleValue;
                continue;
            }
            throw new TypeMismatch();
        }
        Value array;
        vm.pop(array);
        if(!array.isArray)
        {
            throw new TypeMismatch();
        }
        if(array.type == ValueType.IntegerArray)
        {
            vm.push(Value(array.integerArray[index[0..dim]]));
            return;
        }
        if(array.type == ValueType.DoubleArray)
        {
            vm.push(Value(array.doubleArray[index[0..dim]]));
            return;
        }
        if(array.type == ValueType.StringArray)
        {
            vm.push(Value(array.stringArray[index[0..dim]]));
            return;
        }
        if(array.type == ValueType.String)
        {
            if(dim != 1)
            {
                //TODO:syntaxError
                throw new TypeMismatch();
            }
            vm.push(Value(array.stringValue[index[0]].to!wstring));
            return;
        }
        throw new TypeMismatch();
    }
    override string toString(VM vm)
    {
        return "pusharray " ~ dim.to!string;
    }
}
class PushArrayRef : Code
{
    int dim;
    this(int dim)
    {
        this.dim = dim;
    }
    override void execute(VM vm)
    {
        int[4] index;
        for(int i = 0; i < dim; i++)
        {
            Value v;
            vm.pop(v);
            if(v.type == ValueType.Integer)
            {
                index[i] = v.integerValue;
                continue;
            }
            if(v.type == ValueType.Double)
            {
                index[i] = cast(int)v.doubleValue;
                continue;
            }
            throw new TypeMismatch();
        }
        Value array;
        vm.pop(array);
        if(!array.isArray)
        {
            throw new TypeMismatch();
        }
        if(array.type == ValueType.IntegerArray)
        {
            vm.push(Value(&array.integerArray[index[0..dim]]));
            return;
        }
        if(array.type == ValueType.DoubleArray)
        {
            vm.push(Value(&array.doubleArray[index[0..dim]]));
            return;
        }
        if(array.type == ValueType.StringArray)
        {
            vm.push(Value(&array.stringArray[index[0..dim]]));
            return;
        }
        if(array.type == ValueType.String)
        {
            if(dim != 1)
            {
                //TODO:syntaxError
                throw new TypeMismatch();
            }
            //String?
            throw new TypeMismatch();
        }
        throw new TypeMismatch();
    }
    override string toString(VM vm)
    {
        return "pusharrayref " ~ dim.to!string;
    }
}
class PopArray : Code
{
    int var;
    int dim;
    bool local;
    this(int var, int dim, bool local)
    {
        this.var = var;
        this.dim = dim;
        this.local = local;
    }
    override void execute(VM vm)
    {
        Value array;
        if(local)
        {
            array = vm.stack[vm.bp + var];
        }
        else
        {
            array = vm.currentSlot.global[var];
        }
        if(!array.isArray)
        {
            throw new TypeMismatch();
        }
        int[4] index;
        for(int i = 0; i < dim; i++)
        {
            Value v;
            vm.pop(v);
            if(v.type == ValueType.Integer)
            {
                index[i] = v.integerValue;
                continue;
            }
            if(v.type == ValueType.Double)
            {
                index[i] = cast(int)v.doubleValue;
                continue;
            }
            throw new TypeMismatch();
        }
        Value assign;
        vm.pop(assign);
        if(array.type == ValueType.IntegerArray && assign.isNumber)
        {
            array.integerArray[index[0..dim]] = assign.castInteger();
            return;
        }
        if(array.type == ValueType.DoubleArray && assign.isNumber)
        {
            array.doubleArray[index[0..dim]] = assign.castDouble();
            return;
        }
        if(array.type == ValueType.StringArray && assign.type == ValueType.String)
        {
            array.stringArray[index[0..dim]] = assign.stringValue;
            return;
        }
        if(array.type == ValueType.String && assign.type == ValueType.String)
        {
            if(dim != 1)
            {
                //TODO:syntaxError
                throw new TypeMismatch();
            }
            //TODO:文字列の挙動
            throw new TypeMismatch();
            //array.stringValue[index[0]] = assign.stringValue[0];
        }
        throw new TypeMismatch();
    }
    override string toString(VM vm)
    {
        return "poparray " ~ dim.to!string ~ ", " ~ var.to!string ~ ", " ~ local.to!string;
    }
}
class ReturnFunction : Code
{
    Function func;
    this(Function func)
    {
        this.func = func;
    }
    override void execute(VM vm)
    {
        int oldstacki = vm.stacki;
        Value retexpr;
        if(func.returnExpr)
        {
            vm.pop(retexpr);
        }
        vm.stacki = vm.bp + Function.frameSize;//2;
        Value bp, pc;
        vm.poppc;//(pc);
        vm.pop(bp);
        Value hae;
        vm.pop(hae);
        vm.stacki -= func.argCount;
        if(func.returnExpr)
        {
            vm.push(retexpr);
        }
        else
        {
            //OUTの実装
            for(int i = 0; i < func.outArgCount; i++)
            {
                vm.push(vm.stack[vm.bp + i + /*2*/Function.frameSize]);
            }
        }
        //vm.pc = pc.integerValue;
        vm.bp = bp.integerValue;
    }
    override string toString(VM vm)
    {
        return "returnfunc " ~ func.name.to!string;
    }
}
class CallFunctionCode : Code
{
    wstring name;
    int argCount;
    int outArgCount;
    this(wstring name, int argCount)
    {
        this.name = name;
        this.argCount = argCount;
        this.outArgCount = 1;
    }
    this(wstring name, int argCount, int outArgCount)
    {
        this.name = name;
        this.argCount = argCount;
        this.outArgCount = outArgCount;
    }
    Function func;
    void resolve(VM vm)
    {
        func = vm.currentSlot.functions.get(name, null);
        if (!func)
            throw new SyntaxError(name);
    }
    override void execute(VM vm)
    {
        if(!func)
        {
            //楽だし実行時に解決させる
            resolve(vm);
        }
        if(func.argCount != this.argCount)
        {
            throw new IllegalFunctionCall(name.to!string);
        }
        if(func.outArgCount != this.outArgCount)
        {
            throw new IllegalFunctionCall(name.to!string);
        }
        //TODO:args
        auto bp = vm.stacki;
        vm.push(Value());
        vm.push(Value(vm.bp));
        vm.pushpc;//vm.push(Value(vm.pc));
        vm.bp = bp;
        vm.pc = func.address - 1;
        vm.stacki += func.variableIndex - 1;
        foreach(wstring k, VMVariable v ; func.variable)
        {
            if(v.index > 0)
            {
                vm.stack[bp + v.index] = Value(v.type);
            }
        }
    }
    override string toString(VM vm)
    {
        return "callfunc " ~ name.to!string;
    }
}
class CallFunctionS : Code
{
    int argCount;
    int outArgCount;
    this(int argCount, int outArgCount)
    {
        this.argCount = argCount;
        this.outArgCount = outArgCount;
    }
    void callBuintinFunc(BuiltinFunction func, VM vm)
    {
        Value[] arg;
        Value[] oldresult;
        Value[] result;
        arg = vm.stack[vm.stacki - argCount..vm.stacki];
        result = vm.stack[vm.stacki/* - argcount */+ 1..vm.stacki + 1/* - argcount */+ outArgCount];//雑;
        oldresult = result;
        if (argCount != func.argments.length && func.hasSkipArgument)
        {
            auto newarg = new Value[func.argments.length];
            newarg[$ - argCount .. $] = arg[0..$];
            arg = newarg;
        }
        if (outArgCount != func.results.length)
        {
            auto newarg = new Value[func.results.length];
            newarg[$ - outArgCount .. $] = result[0..$];
            result = newarg;
        }
        func.func(vm.petitcomputer, arg, result);
        vm.stacki -= argCount;
        ////vm.stacki += outcount;
        //vm.stacki = old;
        for(int i = 0; i < outArgCount; i++)
        {
            vm.push(result[i]);
        }
    }
    void callFunc(Function func, VM vm)
    {
        if(func.argCount != this.argCount)
        {
            throw new IllegalFunctionCall(func.name.to!string);
        }
        if(func.outArgCount != this.outArgCount)
        {
            throw new IllegalFunctionCall(func.name.to!string);
        }
        //TODO:args
        auto bp = vm.stacki;
        vm.push(Value());
        vm.push(Value(vm.bp));
        vm.pushpc;//vm.push(Value(vm.pc));
        vm.bp = bp;
        vm.pc = func.address - 1;
        vm.stacki += func.variableIndex - 1;
        foreach(wstring k, VMVariable v ; func.variable)
        {
            if(v.index > 0)
            {
                vm.stack[bp + v.index] = Value(v.type);
            }
        }
    }
    override void execute(VM vm)
    {
        Value vname;
        vm.pop(vname);
        if (!vname.isString)
        {
            throw new TypeMismatch();
        }
        auto name = vname.castString.toUpper;
        Function func = vm.currentSlot.functions.get(name, null);
        if(!func)
        {
            auto bfuncs = otya.smilebasic.builtinfunctions.BuiltinFunction.builtinFunctions.get(name, null);
            if (!bfuncs)
            {
                throw new SyntaxError(name);
            }

            auto bfunc = bfuncs.overloadResolution(argCount, outArgCount);
            callBuintinFunc(bfunc, vm);
            return;
        }
        callFunc(func, vm);
    }
    override string toString(VM vm)
    {
        return "callfuncS " ~ argCount.to!string ~ "," ~ outArgCount.to!string;
    }
}
import otya.smilebasic.builtinfunctions;
class CallBuiltinFunction : Code
{
    BuiltinFunction func;
    int argcount;
    int outcount;
    this(BuiltinFunction func, int argcount, int outcount/+可変長引数用+/)
    {
        this.func = func;
        this.argcount = argcount;
        this.outcount = outcount;
    }
    override void execute(VM vm)
    {
        Value[] arg;
        Value[] result;
        if(func.hasSkipArgument)
        {
            arg = vm.stack[vm.stacki - func.argments.length..vm.stacki];
            result = vm.stack[vm.stacki - func.argments.length..vm.stacki - func.argments.length + outcount];//雑;
        }
        else
        {
            arg = vm.stack[vm.stacki - argcount..vm.stacki];
            result = vm.stack[vm.stacki/* - argcount */+ 1..vm.stacki + 1/* - argcount */+ outcount];//雑;
        }
        func.func(vm.petitcomputer, arg, result);
        if(func.variadic)
        {
            vm.stacki -= argcount;
        }
        else
        {
            vm.stacki -= func.argments.length;// - outcount;
        }
        ////vm.stacki += outcount;
        //vm.stacki = old;
        for(int i = 0; i < result.length; i++)
        {
            vm.push(result[i]);
        }
    }
    override string toString(VM vm)
    {
        return "callbuiltin " ~ func.name.to!string;
    }
}
class OnBase : Code
{
    int[] labels;
    this(int[] labels)
    {
        this.labels = labels;
    }
    int on(VM vm)
    {
        Value value;
        vm.pop(value);
        if(!value.isNumber())
        {
            throw new TypeMismatch();
        }
        int index = value.castInteger();
        if(index < 0 || index >= labels.length)
        {
            return -1;
        }
        return labels[index];
    }
}
class OnS : Code
{
    wstring[] labels;
    bool isGosub;
    Scope sc;
    this(wstring[] labels, bool isGosub, Scope sc)
    {
        this.labels = labels;
        this.isGosub = isGosub;
        this.sc = sc;
        this.type = CodeType.OnS;
    }
    override void execute(VM vm)
    {
        stderr.writeln("can't execute (compiler bug?)");
    }
}
class OnGoto : OnBase
{
    this(int[] labels)
    {
        super(labels);
    }
    override void execute(VM vm)
    {
        int index = on(vm);
        if(index < 0) return;
        vm.pc = index - 1;
    }
    override string toString(VM vm)
    {
        return "ongoto " ~ labels.to!string;
    }
}
class OnGosub : OnBase
{
    this(int[] labels)
    {
        super(labels);
    }
    override void execute(VM vm)
    {
        int index = on(vm);
        if(index < 0) return;
        vm.pushpc;//vm.push(Value(vm.pc));
        vm.pc = index - 1;
    }
    override string toString(VM vm)
    {
        return "ongosub " ~ labels.to!string;
    }
}
import std.string;
class InputCode : Code
{
    int count;
    ValueType[] type;
    Value[] output;
    this(int count)
    {
        this.count = count;
        type = new ValueType[count];
        output = new Value[count];
    }
    void exit(int save_SP, VM vm)
    {
        for(int i = save_SP - 1, j = vm.stacki; i > vm.stacki && j <= save_SP; i--, j++)
            std.algorithm.swap(vm.stack[i], vm.stack[j]);
        vm.stacki = save_SP;
    }
    override void execute(VM vm)
    {
        int save_SP = vm.stacki;
        for(int i = 0; i < count; i++)
        {
            Value v;
            vm.pop(v);
            type[i] = v.type;
        }
        bool error;
        do
        {
            if(error)
            {
                vm.petitcomputer.console.printString("?Redo from start \n");
            }
            wstring input = vm.petitcomputer.input("", false);
            wstring[] split = input.split(",");
            error = false;
            if(split.length == 0)
            {
                //スペース以外何も与えないと値を書き換えずに終了する
                exit(save_SP, vm);
                break;
            }
            munch(split[0], " ");
            if(split[0].length == 0)
            {
                //スペース以外何も与えないと値を書き換えずに終了する
                exit(save_SP, vm);
                break;
            }
            if(split.length < count)
            {
                error = true;
                continue;
            }
            foreach(i, s; split)
            {
                if(i >= count)
                {
                    //指定数超えたら無視
                    break;
                }
                //先頭のスペースは無視する
                munch(s, " ");
                if(type[i] == ValueType.Double || type[i] == ValueType.Integer)
                {
                    try
                    {
                        vm.push(Value(to!double(s)));
                    }
                    catch
                    {
                        error = true;
                        break;
                    }
                }
                else
                {
                    vm.push(Value(s));
                }
            }
        } while(error);
    }
    override string toString(VM vm)
    {
        return "input " ~ count.to!string;
    }
}
class ReadCode : Code
{
    int count;
    this(int count)
    {
        this.count = count;
    }
    override void execute(VM vm)
    {
        for(int i = 0; i < count; i++)
        {
            Value data;
            vm.currentSlot.globalDataTable.read(data, vm);
            vm.push(data);
        }
    }
    override string toString(VM vm)
    {
        return "read " ~ count.to!string;
    }
}
class RestoreCodeS : Code
{
    wstring label;
    this(wstring label)
    {
        this.label = label;
        this.type = CodeType.RestoreCodeS;
    }
    override void execute(VM vm)
    {
        stderr.writeln("can't execute (compiler bug?)");
    }
}
class RestoreCode : Code
{
    int label;
    DataTable datatable;
    this(int label, DataTable datatable)
    {
        this.label = label;
        this.datatable = datatable;
    }
    override void execute(VM vm)
    {
        datatable.dataIndex = label;
    }
    override string toString(VM vm)
    {
        return "restore " ~ label.to!string;
    }
}
class RestoreExprCode : Code
{
    DataTable datatable;
    this(DataTable datatable)
    {
        this.datatable = datatable;
    }
    override void execute(VM vm)
    {
        Value label;
        vm.pop(label);
        if(!label.isString)
            throw new TypeMismatch();
        datatable.dataIndex = datatable.label[label.stringValue];
    }
    override string toString(VM vm)
    {
        return "restore expr";
    }
}
class PushSystemVariable : Code
{
    SystemVariable var;
    this(SystemVariable var)
    {
        this.var = var;
    }
    override void execute(VM vm)
    {
        vm.push(var.value);
    }
    override string toString(VM vm)
    {
        return "pushsysvar " ~ var.to!string;
    }
}
class PopSystemVariable : Code
{
    SystemVariable var;
    this(SystemVariable var)
    {
        this.var = var;
    }
    override void execute(VM vm)
    {
        Value v;
        vm.pop(v);
        var.value = v;
    }
    override string toString(VM vm)
    {
        return "popsysvar " ~ var.to!string;
    }
}
class DecSP : Code
{
    override void execute(VM vm)
    {
        vm.decSP;
    }
}
class PopRererence : Code
{
    override void execute(VM vm)
    {
        Value refv, value;
        vm.pop(refv);
        vm.pop(value);
        if (refv.type == ValueType.Reference)
        {
            //TODO:型チェック?
            *refv.reference = value;
            return;
        }
        if (refv.type == ValueType.IntegerReference)
        {
            if (!value.isNumber)
            {
                throw new TypeMismatch();
            }
            *refv.integerReference = value.castInteger;
            return;
        }
        if (refv.type == ValueType.DoubleReference)
        {
            if (!value.isNumber)
            {
                throw new TypeMismatch();
            }
            *refv.doubleReference = value.castDouble;
            return;
        }
        if (refv.type == ValueType.StringReference)
        {
            if (!value.isString)
            {
                throw new TypeMismatch();
            }
            *refv.stringReference = value.castString;
            return;
        }
    }
}
class IncRef : Code
{
    //TODO:文字列INCの挙動
    override void execute(VM vm)
    {
        Value refv;
        vm.pop(refv);
        Value v;
        vm.pop(v);
        if (refv.type == ValueType.Reference)
        {
            if (refv.reference.isNumber && v.isNumber)
            {
                if (refv.reference.isDouble)
                {
                    refv.reference.doubleValue += v.castDouble;
                    return;
                }
                if (refv.reference.isInteger)
                {
                    refv.reference.integerValue += v.castInteger;
                    return;
                }
            }
            if (refv.reference.isString && v.isString)
            {
                refv.reference.stringValue~= v.stringValue;
                return;
            }
        }

        if (refv.type == ValueType.IntegerReference && v.isNumber)
        {
            *refv.integerReference += v.castInteger;
            return;
        }
        if (refv.type == ValueType.DoubleReference && v.isNumber)
        {
            *refv.doubleReference += v.castDouble;
            return;
        }
        if (refv.type == ValueType.StringReference && v.isString)
        {
            *refv.stringReference ~= v.castString;
            return;
        }
        throw new TypeMismatch();
    }
    override string toString(VM vm)
    {
        return "incref";
    }
}

class SwapCode : Code
{
    void getPointer(ref Value v, out int* ip, out double* dp, out wstring* sp)
    {
        ip = null;
        dp = null;
        sp = null;
        if (v.type == ValueType.Reference)
        {
            if(v.reference.type == ValueType.Integer)
            {
                ip = &v.reference.integerValue;
                return;
            }
            if(v.reference.type == ValueType.Double)
            {
                dp = &v.reference.doubleValue;
                return;
            }
            if(v.reference.type == ValueType.String)
            {
                sp = &v.reference.stringValue;
                return;
            }
        }
        if (v.type == ValueType.IntegerReference)
        {
            ip = v.integerReference;
            return;
        }
        if (v.type == ValueType.DoubleReference)
        {
            dp = v.doubleReference;
            return;
        }
        if (v.type == ValueType.StringReference)
        {
            sp = v.stringReference;
            return;
        }
        throw new TypeMismatch();
    }
    override void execute(VM vm)
    {
        Value refitem2, refitem1;
        vm.pop(refitem2);
        vm.pop(refitem1);
        double* dp1, dp2;
        int* ip1, ip2;
        wstring* sp1, sp2;
        getPointer(refitem1, ip1, dp1, sp1);
        getPointer(refitem2, ip2, dp2, sp2);
        if ((sp1 && (dp2 || ip2)) || (sp2 && (dp1 || ip1)))
        {
            throw new TypeMismatch();
        }
        import std.algorithm.mutation : swap;
        if (sp1)
        {
            swap(*sp1, *sp2);
            return;
        }
        if (ip1 && ip2)
        {
            swap(*ip1, *ip2);
            return;
        }
        if (dp1 && dp2)
        {
            swap(*dp1, *dp2);
            return;
        }
        double num1 = ip1 ? *ip1 : *dp1;
        double num2 = ip2 ? *ip2 : *dp2;
        if (ip2)
            *ip2 = cast(int)num1;
        else
            *dp2 = num1;
        if (ip1)
            *ip1 = cast(int)num2;
        else
            *dp1 = num2;
    }
}
