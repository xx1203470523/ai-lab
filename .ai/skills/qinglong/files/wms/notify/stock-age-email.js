'use strict';

const { runTask } = require('../../scripts/utils/http-common');

const URLS = [
  'http://10.10.76.109:12000/job/report/inventory-aging-email/email/send' // lebgjm
];

runTask('库龄物料清单邮件推送', URLS, { method: 'GET', timeoutMs: 600000 }).catch(err => {
  console.error('脚本异常：', err);
  process.exitCode = 1;
});
