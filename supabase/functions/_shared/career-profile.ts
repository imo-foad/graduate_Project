// Explainable career-path inference based on the local skills catalogue. No external AI or paid API.
import type { GradSkill } from "./scoring.ts";
export interface CareerPathMatch { id:string; label:string; score:number; matched_skill_ids:string[] }
interface PathDefinition { id:string; label:string; skills:string[]; minimum_matches:number }
const PATHS:PathDefinition[]=[
{id:"FRONTEND",label:"Frontend Development",skills:["HTML_CSS","JAVASCRIPT","TYPESCRIPT","REACT"],minimum_matches:2},
{id:"BACKEND",label:"Backend Development",skills:["NODE_JS","REST_API","JAVA","PYTHON","C_SHARP","POSTGRESQL","MONGODB"],minimum_matches:2},
{id:"MOBILE",label:"Mobile Development",skills:["KOTLIN","ANDROID","JETPACK_COMPOSE","FLUTTER"],minimum_matches:2},
{id:"DATA_ANALYTICS",label:"Data Analytics",skills:["SQL","PYTHON","POWER_BI","EXCEL","STATISTICS","DATA_VISUALIZATION","TABLEAU","DATA_CLEANING"],minimum_matches:2},
{id:"DATA_SCIENCE",label:"Data Science / Machine Learning",skills:["PYTHON","STATISTICS","MACHINE_LEARNING","DATA_CLEANING","ETL"],minimum_matches:2},
{id:"CYBERSECURITY",label:"Cybersecurity",skills:["CYBERSECURITY","PENETRATION_TESTING","SIEM","NETWORKING","CRYPTOGRAPHY"],minimum_matches:2},
{id:"DEVOPS_CLOUD",label:"DevOps & Cloud",skills:["DOCKER","LINUX","AWS","CLOUD_BASICS","DEVOPS_CI_CD"],minimum_matches:2},
{id:"QA_AUTOMATION",label:"QA & Test Automation",skills:["TESTING","JAVA","PYTHON","JAVASCRIPT"],minimum_matches:2},
{id:"UI_UX",label:"UI/UX Design",skills:["UI_UX","FIGMA","HTML_CSS"],minimum_matches:2},
];
export function deriveCareerProfile(skills:GradSkill[]):{primary_path:CareerPathMatch|null;paths:CareerPathMatch[]} {
 const levels=new Map(skills.map(skill=>[skill.skill_id,skill.level])); const matches:CareerPathMatch[]=[];
 for(const path of PATHS) {
  const matched=path.skills.filter(skill=>(levels.get(skill)??0)>0); if(matched.length<path.minimum_matches)continue;
  const weighted=matched.reduce((sum,skill)=>sum+Math.min(5,levels.get(skill)??0),0);
  matches.push({id:path.id,label:path.label,score:Math.round(weighted/(path.skills.length*5)*100),matched_skill_ids:matched});
 }
 matches.sort((a,b)=>b.score-a.score||b.matched_skill_ids.length-a.matched_skill_ids.length||a.id.localeCompare(b.id));
 return {primary_path:matches[0]??null,paths:matches.slice(0,4)};
}
