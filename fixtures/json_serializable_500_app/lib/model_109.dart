import 'package:json_annotation/json_annotation.dart';

part 'model_109.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model109 {
  const Model109({required this.id, required this.value});

  final int id;
  final String value;

  factory Model109.fromJson(Map<String, dynamic> json) =>
      _$Model109FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model109ToJson(this);
}
