import { ExecuteOrderParams, PolynanceSDK } from "polynance_sdk";
import { Wallet } from "@ethersproject/wallet";
import { JsonRpcProvider } from "@ethersproject/providers";
import dotenv from "dotenv";
dotenv.config();

async function main() {
  try {
    const forkPolygonRpc = process.env.POLYGON_RPC;
    const testPrivateKey = process.env.PRIVATE_KEY;

    if(!forkPolygonRpc || !testPrivateKey) {
        throw new Error("POLYGON_RPC_URL or PRIVATE_KEY is not set");
    }
    const wallet = new Wallet(testPrivateKey, new JsonRpcProvider(forkPolygonRpc));

    //⚡️ Polynance SDK
    const sdk = new PolynanceSDK({wallet,apiBaseUrl:"http://localhost:9000"});
    const targetMarkets = await sdk.search("Japan stock market");
    console.log("targetMarkets", targetMarkets);
    const marketIds = targetMarkets.map((market) => market.event.id);
    console.log("marketIds", marketIds);
    let conditionIds:any[] = [];
    const polymarketGammaEndpoint = "https://gamma-api.polymarket.com/events/";
    for(const marketId of marketIds){
        if(marketId.startsWith("0x"))continue;
        const mm = (await sdk.getMarket("polymarket",marketId)).markets;;
        //@ts-ignore
        const bestExchange = mm.sort((a,b)=>b.liquidity-a.liquidity)[0];
        
        const marketDetails = await fetch(`${polymarketGammaEndpoint}${marketId}`);
        const marketDetailsJson = await marketDetails.json();
        const conditionId = marketDetailsJson.markets[0].conditionId;
        console.log("conditionId", conditionId);
        if(conditionId){
            conditionIds.push({
                conditionId,
                exchangeId:bestExchange.id,
                position: bestExchange.position_tokens.sort((a,b)=>Number(b.price)-Number(a.price))[0].name
            });
        }
        if(conditionIds.length>=4){
            break;
        }
    }
    console.log("conditionIds", conditionIds);
  }catch(error){
    console.log("error", error);
  }
    
}

// Run the main function
main().catch(error => {
  console.error("Unhandled error:", error);
});