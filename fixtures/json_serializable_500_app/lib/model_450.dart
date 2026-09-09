import 'package:json_annotation/json_annotation.dart';

part 'model_450.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model450 {
  const Model450({required this.id, required this.value});

  final int id;
  final String value;

  factory Model450.fromJson(Map<String, dynamic> json) =>
      _$Model450FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model450ToJson(this);
}
