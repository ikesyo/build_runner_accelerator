import 'package:json_annotation/json_annotation.dart';

part 'model_009.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model009 {
  const Model009({required this.id, required this.value});

  final int id;
  final String value;

  factory Model009.fromJson(Map<String, dynamic> json) =>
      _$Model009FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model009ToJson(this);
}
