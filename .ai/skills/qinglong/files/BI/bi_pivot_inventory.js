'use strict';

const { runTask } = require('../scripts/utils/http-common');

// 库存透视表
const URLS = [
  'http://10.10.76.109:12000/bi/report/inventory/pivot/sync',
];

runTask('bi透视表数据推送-库存', URLS, {
  method: 'POST',
  // 该同步接口实际耗时 10~30 分钟。公共库默认 300s，到点只会 req.destroy()
  // 掐断客户端连接，服务端任务照跑，日志里却记成失败。这里放宽到 30 分钟。
  timeoutMs: 1800000
}).catch(err => {
  console.error('脚本异常：', err);
  process.exitCode = 1;
});
