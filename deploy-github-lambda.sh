#!/bin/bash
# One-liner MCP Bridge GitHub fix - run on Mac with AWS CLI
# Usage: curl -sL https://raw.githubusercontent.com/TML-4PM/mcp-scripts/main/deploy-github-lambda.sh | bash -s ghp_YOUR_TOKEN

GITHUB_TOKEN="${1:-$GITHUB_TOKEN}"
REGION="ap-southeast-2"
FUNC="troy-github-operations"
API_ID="m5oqj21chd"

[ -z "$GITHUB_TOKEN" ] && echo "Usage: $0 <github_token>" && exit 1

# Create Lambda code inline
cat > /tmp/gh-ops.js << 'EOF'
const https=require('https');const T=process.env.GITHUB_TOKEN,O=process.env.GITHUB_ORG||'TML-4PM';
async function req(m,p,b=null){return new Promise((r,j)=>{const o={hostname:'api.github.com',path:p,method:m,headers:{'Authorization':`token ${T}`,'User-Agent':'MCP','Accept':'application/vnd.github.v3+json','Content-Type':'application/json'}};const q=https.request(o,s=>{let d='';s.on('data',c=>d+=c);s.on('end',()=>{try{r({status:s.statusCode,data:JSON.parse(d)})}catch(e){r({status:s.statusCode,data:d})}})});q.on('error',j);b&&q.write(JSON.stringify(b));q.end()})}
const h={async list_repos(){const r=await req('GET',`/users/${O}/repos?per_page=100`);return{statusCode:200,body:JSON.stringify({count:r.data.length,repos:r.data.map(x=>({name:x.name,url:x.html_url}))})}},async get_file(repo,path){const r=await req('GET',`/repos/${O}/${repo}/contents/${path}`);if(r.status===200&&r.data.content)return{statusCode:200,body:JSON.stringify({path:r.data.path,sha:r.data.sha,content:Buffer.from(r.data.content,'base64').toString()})};return{statusCode:r.status,body:JSON.stringify(r.data)}},async put_file(repo,path,content,msg,sha){const b={message:msg||`Update ${path}`,content:Buffer.from(content).toString('base64'),branch:'main'};sha&&(b.sha=sha);const r=await req('PUT',`/repos/${O}/${repo}/contents/${path}`,b);return{statusCode:r.status,body:JSON.stringify(r.data)}}};
exports.handler=async e=>{const b=e.body?JSON.parse(e.body):e,a=b.action;if(!a)return{statusCode:200,body:JSON.stringify({actions:Object.keys(h)})};if(!h[a])return{statusCode:400,body:JSON.stringify({error:'Unknown',available:Object.keys(h)})};try{return{...await h[a](b.repo,b.path,b.content,b.message,b.sha),headers:{'Content-Type':'application/json'}}}catch(e){return{statusCode:500,body:JSON.stringify({error:e.message})}}};
EOF

cd /tmp && zip -j gh-ops.zip gh-ops.js

# Deploy Lambda
if aws lambda get-function --function-name $FUNC --region $REGION 2>/dev/null; then
  aws lambda update-function-code --function-name $FUNC --zip-file fileb://gh-ops.zip --region $REGION
else
  aws lambda create-function --function-name $FUNC --runtime nodejs18.x \
    --role arn:aws:iam::140548542136:role/lambda-execution-role \
    --handler gh-ops.handler --zip-file fileb://gh-ops.zip \
    --timeout 30 --memory-size 256 --region $REGION \
    --environment "Variables={GITHUB_TOKEN=$GITHUB_TOKEN,GITHUB_ORG=TML-4PM}"
fi

aws lambda update-function-configuration --function-name $FUNC \
  --environment "Variables={GITHUB_TOKEN=$GITHUB_TOKEN,GITHUB_ORG=TML-4PM}" --region $REGION

# Add API Gateway routes
LAMBDA_ARN="arn:aws:lambda:$REGION:140548542136:function:$FUNC"
INT=$(aws apigatewayv2 create-integration --api-id $API_ID --integration-type AWS_PROXY \
  --integration-uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$LAMBDA_ARN/invocations" \
  --payload-format-version "2.0" --region $REGION --query IntegrationId --output text 2>/dev/null || echo "exists")

[ "$INT" != "exists" ] && for r in "GET /github/repos" "POST /github/file"; do
  aws apigatewayv2 create-route --api-id $API_ID --route-key "$r" --target "integrations/$INT" --region $REGION 2>/dev/null
done

aws lambda add-permission --function-name $FUNC --statement-id api-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:$REGION:140548542136:$API_ID/*/*" --region $REGION 2>/dev/null

echo "✅ Done! Test: curl https://$API_ID.execute-api.$REGION.amazonaws.com/github/repos"
rm -f /tmp/gh-ops.* 2>/dev/null
