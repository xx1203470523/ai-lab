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
    private const int ExportMaxRows = 500000;

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

        var baseQuery = BuildBaseQuery(query);
        var total = await baseQuery.CountAsync();
        if (total > ExportMaxRows)
        {
            throw new CustomException("查询结果过大，请增加查询条件后重试");
        }

        var rows = await baseQuery
            .OrderBy(x => x.BillNo)
            .ToPageListAsync(queryDto.PageNum, queryDto.PageSize);

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
    /// 查询XXX报表列表
    /// </summary>
    public async Task<List<XxxReportDto>> GetListAsync(XxxReportQueryDto queryDto, int maxRows)
    {
        ValidateQueryScope(queryDto);

        var baseQuery = BuildBaseQuery(queryDto);
        var total = await baseQuery.CountAsync();
        if (total > maxRows)
        {
            throw new CustomException("查询结果过大，请增加查询条件后重试");
        }

        var rows = await baseQuery
            .OrderBy(x => x.BillNo)
            .Take(maxRows)
            .ToListAsync();

        await FillPageDataAsync(rows);
        return rows;
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
            var rows = await GetListAsync(queryDto, ExportMaxRows);
            if (rows.Count == 0)
            {
                throw new CustomException("未查询到数据，请检查搜索条件");
            }

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
    /// 构建XXX报表基础查询
    /// </summary>
    private ISugarQueryable<XxxReportDto> BuildBaseQuery(XxxReportQueryDto queryDto)
    {
        return _xxxRepository.Queryable()
            .WhereIF(!string.IsNullOrWhiteSpace(queryDto.BillNo), x => x.BillNo!.StartsWith(queryDto.BillNo))
            .WhereIF(queryDto.StartTime.HasValue, x => x.CreateOn >= queryDto.StartTime)
            .WhereIF(queryDto.EndTime.HasValue, x => x.CreateOn < queryDto.EndTime.Value.AddDays(1))
            .Select(x => new XxxReportDto
            {
                BillNo = x.BillNo
            });
    }

    /// <summary>
    /// 校验XXX报表查询范围
    /// </summary>
    private static void ValidateQueryScope(XxxReportQueryDto queryDto)
    {
        var hasBillNo = !string.IsNullOrWhiteSpace(queryDto.BillNo);
        var hasDateRange = queryDto.StartTime.HasValue && queryDto.EndTime.HasValue;

        if (!hasBillNo && !hasDateRange)
        {
            throw new CustomException("请至少输入单号或时间范围后查询");
        }
    }

    /// <summary>
    /// 填充当前页补充字段
    /// </summary>
    private async Task FillPageDataAsync(List<XxxReportDto> rows)
    {
        if (rows.Count == 0)
        {
            return;
        }

        await Task.CompletedTask;
    }
}
```

## 3. Pattern Notes

- `BuildBaseQuery` 只负责共享查询主体，不处理分页、导出锁或文件生成。
- `ValidateQueryScope` 负责阻断无条件或弱条件大范围查询。
- 分页、列表和导出可以复用基础查询，但不要让导出通过修改 `PageSize` 伪装成分页查询。
- Count 阶段用于提前保护数据库和内存；不要在全量 `ToListAsync` 后才判断数量。
- 当前页补充字段只基于当前页 Id 查询。
- 导出锁以用户维度为默认粒度，避免同一用户反复点击导出。
- 如果 `ToPageListAsync` 在当前项目不可用，使用项目现有等价分页 API；替换前需确认 SqlSugar KB 或现有代码引用。
