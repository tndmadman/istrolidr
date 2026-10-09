// Independent implementation of Istrolid's binary ZJson transport.
// The actual client dictionary stays in the installed local game.
import { readFileSync } from 'node:fs';
const M = Object.freeze({OBJ8:16,OBJ16:17,ARRAY8:32,ARRAY16:33,EMPTY:34,
  TABLE:50,STR8:48,STR16:49,U8:64,U16:65,U32:66,F32:67,TRUE:80,FALSE:81,NULL:82,UNDEF:83});
const END = Buffer.from('END','ascii');
export function loadClientWords(bundlePath) {
  const source = readFileSync(bundlePath,'utf8');
  const segment = source.match(/\/\/from src\/protocol\.js[\s\S]*?(?=\/\/from src\/|$)/);
  if (!segment) throw Error('Istrolid src/protocol.js not found in installed client');
  const match = segment[0].match(/prot\.commonWords\s*=\s*\x60([^\x60]*)\x60\.split\("\\n"\)/);
  if (!match) throw Error('Unsupported client word-table format');
  const words = match[1].split('\n');
  if (words.length > 65536 || words[0] !== '1v1' || !words.includes('playerJoin')) {
    throw Error('Unexpected client word table');
  }
  return words;
}
export class IstrolidZJson {
  constructor(words, { maxBytes=256*1024, maxDepth=32, maxNodes=10000 }={}) {
    if (!Array.isArray(words) || words.length > 65536) throw Error('Invalid string table');
    this.words=words; this.indices=new Map(words.map((w,i)=>[w,i]));
    this.maxBytes=maxBytes; this.maxDepth=maxDepth; this.maxNodes=maxNodes;
  }
  encode(value) {
    const parts=[]; let total=0,nodes=0;
    const push=b=>{total+=b.length;if(total+3>this.maxBytes)throw Error('Packet size limit');parts.push(b);};
    const byte=n=>push(Buffer.from([n]));
    const u16=n=>{const b=Buffer.alloc(2);b.writeUInt16BE(n);push(b);};
    const u32=n=>{const b=Buffer.alloc(4);b.writeUInt32BE(n);push(b);};
    const write=(v,d)=>{
      if(++nodes>this.maxNodes||d>this.maxDepth)throw Error('Packet complexity limit');
      if(v===null){byte(M.NULL);return;}
      if(v===undefined){byte(M.UNDEF);return;}
      if(typeof v==='boolean'){byte(v?M.TRUE:M.FALSE);return;}
      if(typeof v==='number'){
        if(!Number.isFinite(v))throw Error('Invalid number');
        if(Number.isInteger(v)&&v>0&&v<4294967296){
          if(v<256){byte(M.U8);byte(v);}
          else if(v<65536){byte(M.U16);u16(v);}
          else{byte(M.U32);u32(v);}
        }else{
          byte(M.F32);const b=Buffer.alloc(4);b.writeFloatBE(v);push(b);
        }return;
      }
      if(typeof v==='string'){
        const index=this.indices.get(v);
        if(index!==undefined){byte(M.TABLE);u16(index);return;}
        if(v.length>=65536)throw Error('String too long');
        if(v.length<256){byte(M.STR8);byte(v.length);}
        else{byte(M.STR16);u16(v.length);}
        const b=Buffer.alloc(v.length);
        for(let i=0;i<v.length;i++)b[i]=v.charCodeAt(i)&255;
        push(b);return;
      }
      if(Array.isArray(v)){
        if(v.length>=65536)throw Error('Array too long');
        if(v.length<=4)byte(M.EMPTY+v.length);
        else if(v.length<256){byte(M.ARRAY8);byte(v.length);}
        else{byte(M.ARRAY16);u16(v.length);}
        for(const item of v)write(item,d+1);return;
      }
      if(!v||typeof v!=='object'||Object.getPrototypeOf(v)!==Object.prototype)throw Error('Unsupported object');
      const keys=Object.keys(v);
      if(keys.length>=65536)throw Error('Object too large');
      if(keys.length<256){byte(M.OBJ8);byte(keys.length);}
      else{byte(M.OBJ16);u16(keys.length);}
      for(const k of keys){write(k,d+1);write(v[k],d+1);}
    };
    write(value,0);push(END);return Buffer.concat(parts,total);
  }
  decode(frame) {
    const b=Buffer.from(frame);
    if(b.length<4||b.length>this.maxBytes)throw Error('Invalid packet length');
    let offset=0,nodes=0;
    const take=n=>{if(offset+n>b.length)throw Error('Truncated packet');const i=offset;offset+=n;return i;};
    const u8=()=>b.readUInt8(take(1)),u16=()=>b.readUInt16BE(take(2));
    const read=d=>{
      if(++nodes>this.maxNodes||d>this.maxDepth)throw Error('Packet complexity limit');
      const mark=u8();
      if(mark===M.NULL)return null;
      if(mark===M.UNDEF)return undefined;
      if(mark===M.TRUE)return true;
      if(mark===M.FALSE)return false;
      if(mark===M.U8)return u8();
      if(mark===M.U16)return u16();
      if(mark===M.U32)return b.readUInt32BE(take(4));
      if(mark===M.F32){const v=b.readFloatBE(take(4));if(!Number.isFinite(v))throw Error('Invalid float');return v;}
      if(mark===M.TABLE){const i=u16();if(i>=this.words.length)throw Error('Bad dictionary index');return this.words[i];}
      if(mark===M.STR8||mark===M.STR16){const n=mark===M.STR8?u8():u16();const start=take(n);return b.toString('latin1',start,start+n);}
      if((mark>=M.EMPTY&&mark<=M.EMPTY+4)||mark===M.ARRAY8||mark===M.ARRAY16){
        const n=mark===M.ARRAY8?u8():mark===M.ARRAY16?u16():mark-M.EMPTY;
        if(n>this.maxNodes-nodes)throw Error('Array node budget');
        const a=[];for(let i=0;i<n;i++)a.push(read(d+1));return a;
      }
      if(mark===M.OBJ8||mark===M.OBJ16){
        const n=mark===M.OBJ8?u8():u16();
        if(n*2>this.maxNodes-nodes)throw Error('Object node budget');
        const obj=Object.create(null);
        for(let i=0;i<n;i++){
          const key=read(d+1);
          if(typeof key!=='string'||['__proto__','prototype','constructor'].includes(key)||Object.hasOwn(obj,key))throw Error('Invalid key');
          obj[key]=read(d+1);
        }
        return obj;
      }
      throw Error('Unsupported ZJson marker '+mark);
    };
    const value=read(0);
    if(b.length-offset!==3||!b.subarray(offset).equals(END))throw Error('Missing END terminator');
    return value;
  }
}
