# Report Template Reference

本文件提供 WMS 报表新增/优化的参考骨架。它不是规则来源；实际强约束以 `rules/packs/service-report.rules.md` 及命中的 Service / DTO / Repository / Controller 规则包为准。

## 1. DTO Shape

```csharp
/// <summary>
/// XXX报表查询条件
/// </summary>
public class XxxReportQueryDto
{
    /// <summary>
    /// 单号
    /// </summary>
    public string? BillNo { get; set; }

    /// <summary>
    /// 开始时间
    /// </summary>
    public DateTime? StartTime { get; set; }

    /// <summary>
    /// 结束时间
    /// </summary>
    public DateTime? EndTime { get; set; }
}

/// <summary>
/// XXX报表分页查询条件
/// </summary>
public class XxxReportPagedQueryDto : PagerQuery
{
    /// <summary>
    /// 单号
    /// </summary>
    public string? BillNo { get; set; }

    /// <summary>
    /// 开始时间
    /// </summary>
    public DateTime? StartTime { get; set; }

    /// <summary>
    /// 结束时间
    /// </summary>
    public DateTime? EndTime { get; set; }
}

/// <summary>
/// XXX报表页面响应
/// </summary>
public class XxxReportDto
{
    /// <summary>
    /// 单号
    /// </summary>
    public string? BillNo { get; set; }
}

/// <summary>
/// XXX报表导出响应
/// </summary>
public class XxxReportExportDto
{
    /// <summary>
    /// 单号
    /// </summary>
    [ExcelColumnName("单号")]
    public string? BillNo { get; set; }
}
```

## 2. Service Skeleton

```csharp
/// <summary>
/// XXX报表服务
/// </summary>
public class XxxReportService : IXxxReportService, ITransient
{
    private const int ExportMaxRows = 100000;

    private readonly XxxRepository _xxxRepository;
    private readonly ICachingService _cachingService;

    /// <summary>
    /// 构造函数
    /// </summary>
    public XxxReportService(XxxRepository xxxRepository, ICachingService cachingService)
    {
        _xxxRepository = xxxRepository;
        _cachingService = cachingService;
    }

    /// <summary>
    /// 分页查询XXX报表
    /// </summary>
    public async Task<PagedInfo<XxxReportDto>> GetPagedAsync(XxxReportPagedQueryDto queryDto)
    {
        var query = queryDto.Adapt<XxxReportQueryDto>();
        ValidateQueryScope(query);

        // 分页用最小 JOIN + EXISTS，不加 OrderBy
        var baseQuery = BuildPagedQuery(query);
        var total = await baseQuery.CountAsync();
        if (total > ExportMaxRows)
        {
            throw new CustomException("查询结果过大，请增加查询条件后重试");
        }

        var rows = await baseQuery.ToPageListAsync(queryDto.PageNum, queryDto.PageSize);

        // 按当前页 ID 后填充
        await FillPageDataAsync(rows);

        return new PagedInfo<XxxReportDto>
        {
            Result = rows,
            TotalNum = total,
            PageIndex = queryDto.PageNum,
            PageSize = queryDto.PageSize,
            TotalPage = (int)Math.Ceiling(total / (double)queryDto.PageSize)
        };
    }

    /// <summary>
    /// 导出XXX报表
    /// </summary>
    public async Task<string> ExportAsync(XxxReportQueryDto queryDto)
    {
        var lockKey = $"XxxReportService:ExportAsync:{WMSApp.GetUserId()}";
        var locked = await _cachingService.LockAsync(lockKey);
        if (!locked)
        {
            throw new CustomException("正在导出，请稍后重试");
        }

        try
        {
            ValidateQueryScope(queryDto);

            // 导出 COUNT 用核心表（分页查询），不是导出 JOIN
            var countQuery = BuildPagedQuery(queryDto);
            var total = await countQuery.CountAsync();
            if (total > ExportMaxRows)
            {
                throw new CustomException($"导出数据量超过{ExportMaxRows}条上限，请缩小查询范围");
            }
            if (total == 0)
            {
                throw new CustomException("未查询到数据，请检查搜索条件");
            }

            // 导出用完整 JOIN 拿全字段，不加 OrderBy
            var exportQuery = BuildExportQuery(queryDto);
            var rows = await exportQuery.ToListAsync();

            // 导出后填充：跳过导出 SELECT 已有的表
            await FillExportDataAsync(rows, skipDetailQuery: true);

            var exportRows = rows.Adapt<List<XxxReportExportDto>>();
            var filePath = HandleExcelHepler.GetFilePath("XXX报表", out var fileName);
            MiniExcel.SaveAs(filePath, exportRows, excelType: ExcelType.XLSX);
            return fileName;
        }
        finally
        {
            await _cachingService.LockReleaseAsync(lockKey);
        }
    }

    /// <summary>
    /// 构建分页查询（最小 JOIN + EXISTS 子查询处理跨表条件，不加 OrderBy）
    /// </summary>
    private ISugarQueryable<XxxReportDto> BuildPagedQuery(XxxReportQueryDto queryDto)
    {
        // 核心表（2-3 表）
        var query = _headRepository.Queryable()
            .LeftJoin<InStockReceiptDetail>((h, d) => h.Id == d.ReceiptHeadId);

        // 直接条件
        query = query
            .WhereIF(!string.IsNullOrWhiteSpace(queryDto.BillNo), h => h.BillNo!.StartsWith(queryDto.BillNo))
            .WhereIF(queryDto.StartTime.HasValue, h => h.CreateOn >= queryDto.StartTime)
            .WhereIF(queryDto.EndTime.HasValue, h => h.CreateOn < queryDto.EndTime.Value.AddDays(1));

        // 跨表条件用 EXISTS
        if (!string.IsNullOrWhiteSpace(queryDto.CheckNo))
        {
            query = query.Where(h => SqlFunc.Subqueryable<QualChecklistDetail>()
                .Where(cd => cd.ReceiptId == h.Id && cd.CheckNo!.StartsWith(queryDto.CheckNo))
                .Any());
        }

        return query.Select((h, d) => new XxxReportDto
        {
            BillNo = h.BillNo,
            Id = h.Id,
        });
    }

    /// <summary>
    /// 构建导出查询（完整 JOIN 拿全字段，不加 OrderBy）
    /// </summary>
    private ISugarQueryable<XxxReportDto> BuildExportQuery(XxxReportQueryDto queryDto)
    {
        var query = _headRepository.Queryable()
            .LeftJoin<InStockArnHead>((a, b) => a.Id == b.ReceiptHeadId)
            .LeftJoin<QualChecklist>((a, b, c) => a.Id == c.ReceiptId)
            .LeftJoin<InStockAsnHead>((a, b, c, d) => b.AsnId == d.Id)
            .LeftJoin<InStockReceiptDetail>((a, b, c, d, e) => a.Id == e.ReceiptHeadId);

        // 直接条件（与分页查询同构）
        query = query
            .WhereIF(!string.IsNullOrWhiteSpace(queryDto.BillNo), a => a.BillNo!.StartsWith(queryDto.BillNo))
            .WhereIF(queryDto.StartTime.HasValue, a => a.CreateOn >= queryDto.StartTime)
            .WhereIF(queryDto.EndTime.HasValue, a => a.CreateOn < queryDto.EndTime.Value.AddDays(1));

        // 跨表条件同样用 EXISTS
        if (!string.IsNullOrWhiteSpace(queryDto.CheckNo))
        {
            query = query.Where(a => SqlFunc.Subqueryable<QualChecklistDetail>()
                .Where(cd => cd.ReceiptId == a.Id && cd.CheckNo!.StartsWith(queryDto.CheckNo))
                .Any());
        }

        // SELECT 一次性拿全，导出后填充跳过这些表
        return query.Select((a, b, c, d, e) => new XxxReportDto
        {
            BillNo = a.BillNo,
            Id = a.Id,
            ArnNo = b.ArnNo,           // 导出 SELECT 已有 → FillExport 跳过
            CheckNo = c.CheckNo,        // 导出 SELECT 已有 → FillExport 跳过
            DetailCount = e.Count,      // 导出 SELECT 已有 → FillExport 跳过
        });
    }

    /// <summary>
    /// 校验查询范围（含默认时间范围兜底）
    /// </summary>
    private static void ValidateQueryScope(XxxReportQueryDto queryDto)
    {
        // 无结束时间 → 默认当日 23:59:59
        var now = DateTime.Now;
        var endTime = queryDto.EndTime ?? new DateTime(now.Year, now.Month, now.Day, 23, 59, 59);
        // 无开始时间 → 默认一个月前
        var startTime = queryDto.StartTime ?? endTime.AddMonths(-1).Date;

        // 跨度上限：不超过一个月
        if (endTime.Date > startTime.Date.AddMonths(1))
            throw new CustomException("查询时间范围不能超过一个月");

        var hasBillNo = !string.IsNullOrWhiteSpace(queryDto.BillNo);
        if (!hasBillNo && !queryDto.StartTime.HasValue && !queryDto.EndTime.HasValue)
            throw new CustomException("请至少输入单号或时间范围后查询");

        queryDto.StartTime = startTime;
        queryDto.EndTime = endTime;
    }

    /// <summary>
    /// 填充当前页补充字段（基于当前页 ID 集合）
    /// </summary>
    private async Task FillPageDataAsync(List<XxxReportDto> rows)
    {
        if (rows.Count == 0) return;

        var headIds = rows.Select(r => r.Id).Distinct().ToList();

        // 按当前页 ID 查询关联数据，ILookup O(1) 索引取值
        var details = await _detailRepository.Queryable()
            .Where(d => headIds.Contains(d.ReceiptHeadId))
            .ToListAsync();
        var detailLookup = details.ToLookup(d => d.ReceiptHeadId);

        foreach (var row in rows)
        {
            var rowDetails = detailLookup[row.Id].ToList();
            row.DetailCount = rowDetails.Count;
        }
    }

    /// <summary>
    /// 填充导出补充字段（跳过导出 SELECT 已有的表）
    /// </summary>
    private async Task FillExportDataAsync(List<XxxReportDto> rows, bool skipDetailQuery)
    {
        if (rows.Count == 0) return;

        // 导出 SELECT 已有的表不再重复查询
        // 只填充导出未 JOIN 的数据（如用户字典、上架字段等）
    }
}
```

## 3. Pattern Notes

- `BuildPagedQuery`：最小 JOIN（2-3 表），跨表条件用 EXISTS 子查询，不加 OrderBy。只 SELECT 后填充拿不到的字段。
- `BuildExportQuery`：完整 JOIN（5-8 表），SELECT 一次性拿全让 DB 发挥 JOIN 性能，不加 OrderBy。后填充跳过已获取的表。
- `ValidateQueryScope`：无时间条件时默认近一个月，最大跨度一个月，超限抛异常。
- 分页和导出**禁止共用**同一个查询构建器。
- 导出 COUNT 用 `BuildPagedQuery().CountAsync()`（核心表），不是 `BuildExportQuery().CountAsync()`（全 JOIN）。
- COUNT 阶段用于提前保护数据库和内存；不要在全量 `ToListAsync` 后才判断数量。
- 当前页补充字段只基于当前页 ID 集合查询，使用 ILookup 索引取值。
- 导出锁以用户维度为默认粒度，`finally` 中释放，未取得锁不得释放。
- 雪花 ID 主键 + 聚簇索引自然有序，不额外加排序增加开销。
