import type { CellDTO } from "../../kernel/types";
export interface DriftOffset {frame:number;dxPx:number;dyPx:number;matchedObjects:number}
const median=(values:number[])=>{if(!values.length)return 0;const s=values.slice().sort((a,b)=>a-b);return (s[Math.floor((s.length-1)/2)]+s[Math.floor(s.length/2)])/2;};
function nearest(from:CellDTO[],to:CellDTO[],gate:number,budget={comparisons:0}):number[] {
  const grid=new Map<string,number[]>();
  to.forEach((cell,index)=>{const key=`${Math.floor(cell.cx/gate)}:${Math.floor(cell.cy/gate)}`;const bucket=grid.get(key)??[];bucket.push(index);grid.set(key,bucket);});
  return from.map(cell=>{let best=-1,distance=gate*gate;const gx=Math.floor(cell.cx/gate),gy=Math.floor(cell.cy/gate);for(let y=gy-1;y<=gy+1;y++)for(let x=gx-1;x<=gx+1;x++)for(const index of grid.get(`${x}:${y}`)??[]){if(++budget.comparisons>5_000_000)throw new Error("Dense centroid search exceeds five million comparisons; use fewer masks or a smaller field");const target=to[index],d=(target.cx-cell.cx)**2+(target.cy-cell.cy)**2;if(d<distance || d===distance && index<best){best=index;distance=d;}}return best;});
}
export function estimateDrift(frames:CellDTO[][],gate=120):DriftOffset[]{
  if(!Number.isFinite(gate)||gate<=0)throw new Error("Drift gate must be positive");
  if(frames.length>512||frames.some(frame=>frame.length>100_000)||frames.reduce((sum,frame)=>sum+frame.length,0)>200_000)throw new Error("Sequence exceeds the bounded correction workspace");
  const budget={comparisons:0};let dx=0,dy=0;return frames.map((frame,index)=>{let matched=0;if(index){const previous=frames[index-1],forward=nearest(previous,frame,gate,budget),back=nearest(frame,previous,gate,budget),xs:number[]=[],ys:number[]=[];forward.forEach((j,i)=>{if(j>=0&&back[j]===i){xs.push(frame[j].cx-previous[i].cx);ys.push(frame[j].cy-previous[i].cy);}});matched=xs.length;if(matched){dx+=median(xs);dy+=median(ys);}}return{frame:index,dxPx:dx,dyPx:dy,matchedObjects:matched};});
}
export function translatedCell(cell:CellDTO,dx:number,dy:number,pxPerUm:number):CellDTO {
  return {...cell,id:crypto.randomUUID(),cx:cell.cx+dx,cy:cell.cy+dy,centroidUmX:(cell.cx+dx)/pxPerUm,centroidUmY:(cell.cy+dy)/pxPerUm,diameterUm:cell.diameterPx/pxPerUm,areaUm2:cell.areaUm2===undefined?undefined:cell.areaUm2*(cell.diameterPx/cell.diameterUm/pxPerUm)**2,meanIntensity:undefined,integratedDensity:undefined,contourPx:cell.contourPx?.map(([x,y])=>[x+dx,y+dy]),isManual:true};
}
export function disagreements(primary:CellDTO[],opinion:CellDTO[]):Set<string>{
  const gate=Math.max(4,median(primary.map(cell=>cell.diameterPx))*.5),matches=nearest(primary,opinion,gate);
  return new Set(primary.filter((cell,i)=>matches[i]<0||Math.abs(opinion[matches[i]].diameterPx-cell.diameterPx)>cell.diameterPx*.35).map(cell=>cell.id));
}
export function riskScore(cells:CellDTO[],stats?:Record<string,number>):number {
  if(!cells.length)return 0;
  const uncertainty=cells.reduce((sum,cell)=>sum+1-cell.confidence,0)/cells.length;
  const flags=cells.filter(cell=>cell.edgeTouching||cell.likelyClump||cell.likelyDebris).length/cells.length;
  const focus=stats?.focus_score;return Math.min(1,uncertainty*.6+flags*.25+(focus===undefined?0:Math.max(0,1-focus)*.15));
}
function resampleContour(points:[number,number][],count=96):[number,number][]{
  const ring=points.slice();if(ring.length>1&&ring[0][0]===ring[ring.length-1][0]&&ring[0][1]===ring[ring.length-1][1])ring.pop();
  if(ring.length<3||ring.length>10000||ring.some(p=>p.length!==2||p.some(v=>!Number.isFinite(v))))throw new Error("Interpolation requires finite complete contours");
  const lengths=ring.map((p,i)=>Math.hypot(p[0]-ring[(i+1)%ring.length][0],p[1]-ring[(i+1)%ring.length][1]));const perimeter=lengths.reduce((a,b)=>a+b,0);if(perimeter<=0)throw new Error("Degenerate interpolation contour");
  const result:[number,number][]=[];let segment=0,start=0;
  for(let sample=0;sample<count;sample++){const distance=sample*perimeter/count;while(segment<ring.length-1&&start+lengths[segment]<distance){start+=lengths[segment++];}const ratio=lengths[segment]? (distance-start)/lengths[segment]:0,a=ring[segment],b=ring[(segment+1)%ring.length];result.push([a[0]+(b[0]-a[0])*ratio,a[1]+(b[1]-a[1])*ratio]);}return result;
}
const signedArea=(p:[number,number][])=>p.reduce((sum,a,i)=>{const b=p[(i+1)%p.length];return sum+a[0]*b[1]-b[0]*a[1];},0)/2;
export function interpolateCell(a:CellDTO,b:CellDTO,t:number,pxPerUm:number):CellDTO {
  if(!a.contourPx||!b.contourPx)throw new Error("Interpolation requires complete start and endpoint contours; circle substitution is unavailable");
  const start=resampleContour(a.contourPx),end=resampleContour(b.contourPx);if(Math.sign(signedArea(start))!==Math.sign(signedArea(end)))end.reverse();
  let phase=0,best=Infinity;for(let offset=0;offset<end.length;offset++){let score=0;for(let i=0;i<start.length;i++){const q=end[(i+offset)%end.length];score+=(start[i][0]-a.cx-(q[0]-b.cx))**2+(start[i][1]-a.cy-(q[1]-b.cy))**2;}if(score<best){best=score;phase=offset;}}
  const contourPx=start.map(([x,y],i):[number,number]=>{const q=end[(i+phase)%end.length];return[x+(q[0]-x)*t,y+(q[1]-y)*t];});const area=Math.abs(signedArea(contourPx));if(area<1)throw new Error("Interpolated contour collapses; choose compatible anchors");
  const diameterPx=2*Math.sqrt(area/Math.PI),cx=a.cx+(b.cx-a.cx)*t,cy=a.cy+(b.cy-a.cy)*t;contourPx.push(contourPx[0]);
  return{id:crypto.randomUUID(),cx,cy,diameterPx,diameterUm:diameterPx/pxPerUm,areaUm2:area/pxPerUm**2,centroidUmX:cx/pxPerUm,centroidUmY:cy/pxPerUm,confidence:Math.min(a.confidence,b.confidence),isManual:true,contourPx};
}
