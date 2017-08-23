package tink.hxx;

import haxe.macro.Expr;
import tink.hxx.Node;
import tink.parse.Char.*;
import tink.parse.ParserBase;
import tink.parse.StringSlice;
import haxe.macro.Context;
import tink.hxx.Parser.ParserConfig;

using StringTools;
using haxe.io.Path;
using tink.MacroApi;
using tink.CoreApi;

typedef ParserConfig = {
  defaultExtension:String,
  ?defaultSwitchTarget:Expr,
  ?noControlStructures:Bool,
  ?isVoid:String->Bool,
  //?interceptTag:String->Option<StringAt->Expr>, <--- consider adding this back
}

class Parser extends ParserBase<Position, haxe.macro.Error> { 
  
  var fileName:String;
  var offset:Int;
  var config:ParserConfig;
  var isVoid:String->Bool;
  
  public function new(fileName, source, offset, config) {
    this.fileName = fileName;
    this.offset = offset;
    this.config = config;
    super(source);
    
    function get<T>(o:{ var isVoid(default, null):T; }) return o.isVoid;

    this.isVoid = switch get(config) {
      case null: function (_) return false;
      case v: v;
    }
  }
  
  function withPos(s:StringSlice, ?transform:String->String):StringAt {
    return {
      pos: doMakePos(s.start, s.end),
      value: switch transform {
        case null: s.toString();
        case v: v(s);
      },
    }
  }
  
  function processExpr(e:Expr) 
    return
      #if tink_syntaxhub
        switch tink.SyntaxHub.exprLevel.appliedTo(new ClassBuilder()) {
          case Some(f): f(e);
          case None: e;
        }
      #else
        e;
      #end

  function parseExpr(source, pos) 
    return
      processExpr( 
        try Context.parseInlineString(source, pos)
        catch (e:haxe.macro.Error) throw e
        catch (e:Dynamic) pos.error(e)
      );

  function simpleIdent() {
    var name = withPos(ident(true).sure());
    return macro @:pos(name.pos) $i{name.value};
  }
    
  function argExpr()
    return 
      if (allow("${") || allow('{')) 
        Success(ballancedExpr('{', '}'));
      else if (allow("$")) 
        Success(simpleIdent());
      else 
        Failure(makeError('expression expected', makePos(pos, pos)));
    
  function ballancedExpr(open:String, close:String) {
    var src = ballanced(open, close);
    return parseExpr(src.value, src.pos);
  }
  
  function ballanced(open:String, close:String) {
    var start = pos;
    var ret = null;
    do {
      if (!upto(close).isSuccess())
        die('Missing corresponding `$close`', start...start+1);
      
      var inner = withPos(source[start...pos-1]);
      
      if (inner.value.split(open).length == inner.value.split(close).length)
        ret = inner;
    } while (ret == null);
    
    return ret;          
  }
  
  function kwd(name:String) {
    if (config.noControlStructures) return false;
    var pos = pos;
    var isIf = isNext('if');
    
    var found = switch ident(true) {
      case Success(v) if (v == name): true;
      default: false;
    }
    
    if (!found) this.pos = pos;
    return found;
  }
  
  function parseChild() return located(function () {
    var name = withPos(ident(true).sure());
    
    var hasChildren = true;
    var attrs = new Array<Attribute>();
    
    while (!allow('>')) {
      if (allow('/')) {
        expect('>');
        hasChildren = false;
        break;
      }
      
      if (allow('{')) {
        var pos = pos;
        
        if (allow('...')) {
          attrs.push(Splat(ballancedExpr('{', '}')));
          continue;
        }
        die('unexpected {');
      }
      var attr = withPos(ident().sure());
              
      attrs.push(
        if (allow('=')) 
          Regular(attr, switch argExpr() {
            case Success(e): e;
            default:
              var s = parseString();
              EConst(CString(s.value)).at(s.pos);
          })
        else
          Empty(attr)
      );
    }
    
    return CNode({
      name: name, 
      attributes: attrs, 
      children: if (hasChildren && !isVoid(name.value)) parseChildren(name.value) else null
    });
  });
  
  function parseString()
    return expect('"') + withPos(upto('"').sure(), StringTools.htmlUnescape);
  
  function parseChildren(?closing:String):Children {
    var ret:Array<Child> = [],
        start = pos;    

    function result():Children return {
      pos: makePos(start, pos),
      value: ret,
    }  

    function expr(e:Expr)
      ret.push({
        pos: e.pos,
        value: CExpr(e),
      });    

    function text(slice) {
      var text = withPos(slice, StringTools.htmlUnescape);
      ret.push({
        pos: text.pos,
        value: CText(text) 
      });
    }      
    
    while (pos < max) {  
      
      switch first(["${", "$", "{", "<"], text) {
        case Success("<"):
          if (allowHere('!--')) 
            upto('-->', true);            
          else if (allowHere('!'))
            die('Invalid comment or unsupported processing instruction');
          else if (allowHere('/')) {
            var found = ident(true).sure();
            expectHere('>');
            if (found != closing)
              die(
                if (isVoid(found))
                  'invalid closing tag for void element <$found>'
                else
                  'found </$found> but expected </$closing>', 
                found.start...found.end
              );
            return result();
          }
          else if (kwd('for')) {
            ret.push(located(function () {
              return CFor(argExpr().sure() + expect('>'), parseChildren('for'));
            }));
          }
          else if (kwd('switch')) 
            ret.push(parseSwitch());
          else if (kwd('if')) 
            ret.push(parseIf());
          else if (kwd('else')) 
            throw new Else(result(), false);
          else if (kwd('elseif')) 
            throw new Else(result(), true);
          else if (kwd('case')) 
            throw new Case(result());
          else 
            ret.push(parseChild());        
          
        case Success("$"):
          
          expr(simpleIdent());
          
        case Success(v):
          
          if (allow('import')) {
            
            var file = parseString();
            
            expect('}');
                        
            var name = file.value;
            
            if (name.extension() == '')
              name = '$name.${config.defaultExtension}';
                          
            if (!name.startsWith('./'))
              name = Path.join([fileName.directory(), name]);
              
            var content = 
              try
                sys.io.File.getContent(name)
              catch (e:Dynamic)
                file.pos.error(e);
            
            Context.registerModuleDependency(Context.getLocalModule(), name);
                
            var p = new Parser(name, content, 0, config);
            for (c in p.parseChildren().value)
              ret.push(c);
            
          }
          else
            expr(ballancedExpr('{', '}'));
            
        case Failure(e):
          this.skipIgnored();
          if (this.pos < this.max)
            e.pos.error(e.message);
      }
            
    }
    
    if (closing != null)
      die('unclosed <$closing>');
    
    return result();
  };
  
  function parseSwitch() return located(function () return {
    var target = 
      (switch [argExpr(), config.defaultSwitchTarget] {
        case [Success(v), _]: v;
        case [Failure(v), null]: throw v;
        case [_, v]: v;
      }) + expect('>') + expect('<case');
    
    var cases = [];
    var ret = CSwitch(target, cases);
    var last = false;
    while (!last) {
      var arg = argExpr().sure();
      cases.push({
        values: [arg],
        guard: (if (allow('if')) argExpr().sure() else null) + expect('>'),
        children:
          try {
            last = true;
            parseChildren('switch');
          }
          catch (e:Case) {
            last = false;
            e.children;
          }
      });
    }
    return ret;
  });

  function located<T>(f:Void->T):Located<T> {
    //this is not unlike read
    var start = pos;
    var ret = f();
    return {
      value: ret,
      pos: makePos(start, pos)
    }
  }

  function onlyChild(c:Child):Children
    return { pos: c.pos, value: [c] };
  
  function parseIf():Child {
    var start = pos;
    var cond = argExpr().sure() + expect('>');
    
    function make(cons, ?alt):Child {
      
      return {
        pos: makePos(start, pos),
        value: CIf(cond, cons, alt)
      }
    }
    return 
      try {
        make(parseChildren('if'));
      }
      catch (e:Else) {
        if (e.elseif || switch ident() { case Success(v): if (v == 'if') true else die('unexpected $v', v.start...v.end); default: false; } ) 
          make(e.children, onlyChild(parseIf()));
        else
          expect('>') + make(e.children, parseChildren('if'));
      }
  }
  
  static var IDENT_START = UPPER || LOWER || '_'.code;
  static var IDENT_CONTD = IDENT_START || DIGIT || '-'.code || '.'.code;
  
  function ident(here = false) 
    return 
      if ((here && is(IDENT_START)) || (!here && upNext(IDENT_START)))
        Success(readWhile(IDENT_CONTD));
      else 
        Failure(makeError('Identifier expected', makePos(pos)));  
  
  override function doMakePos(from:Int, to:Int):Position
    return 
      #if macro Context.makePosition #end ({ min: from + offset, max: to + offset, file: fileName });
  
  override function makeError(message:String, pos:Position)
    return 
      new haxe.macro.Expr.Error(message, pos);
  
  override function doSkipIgnored() {
    doReadWhile(WHITE);
    
    if (allow('//'))
      doReadWhile(function (c) return c != 10);
      
    if (allow('/*'))
      upto('*/').sure();
      
    if (allow('#if')) {
      throw 'not implemented';
    }
  }  
  
  static public function parse(e:Expr, gen:Generator, ?config:ParserConfig) {
    if (config == null) 
      config = {
        defaultExtension: 'hxx',
        noControlStructures: false,
      }
      
    var s = e.getString().sure();
    var pos = Context.getPosInfos(e.pos);
    var p = new Parser(pos.file, s, pos.min + 1, config);
    p.skipIgnored();
    return try {
      NodeWalker.root(gen, p.parseChildren());
    }
    catch (e:Case) 
      p.die('case outside of switch', p.pos - 4 ... p.pos)
    catch (e:Else)
      p.die('else without if', p.pos - 4 ... p.pos);
  }

}

private class NodeWalker {
  
  static public function root(gen:Generator, children:Children) {
    var wrapped = new NodeWalker(gen);
    return gen.root(wrapped.children(children));
  }

  var gen:Generator;
  function new(gen)
    this.gen = gen;

  function child(c:Child):Option<Expr>
    return switch c.value {
      case CIf(cond, cons, alt): 
        Some(macro @:pos(c.pos) if ($cond) ${flatten(cons)} else ${flatten(alt)});
      case CSwitch(target, cases):
        Some(ESwitch(target, [for (c in cases) {
          values: c.values,
          guard: c.guard,
          expr: flatten(c.children),
        }], null).at(c.pos));
      case CFor(head, body):
        Some(gen.flatten(c.pos, [macro @:pos(c.pos) for ($head) ${flatten(body)}]));
      case CExpr(e): Some(e);
      case CText(s): gen.string(s);
      case CNode(n): Some(gen.makeNode(n.name, n.attributes, children(n.children)));
    }

  function flatten(c:Children) 
    return 
      if (c == null) gen.flatten((macro null).pos, null);
      else gen.flatten(c.pos, children(c));

  function children(c:Children):Array<Expr>
    return
      if (c == null) null;
      else 
        [for (c in c.value) switch child(c) {
          case Some(e): e;
          case None: continue;
        }];
}

private class Branch {
  
  public var children(default, null):Children;
  
  public function new(children)
    this.children = children;
    
  public function toString() 
    return 'mispaced ${Type.getClassName(Type.getClass(this))}';
}

private class Case extends Branch { 
  
}
private class Else extends Branch { 
  
  public var elseif(default, null):Bool;
  
  public function new(children, elseif) {
    super(children);
    this.elseif = elseif;
  }
  
}
