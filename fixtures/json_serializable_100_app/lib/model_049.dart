import 'package:json_annotation/json_annotation.dart';

part 'model_049.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model049 {
  const Model049({required this.id, required this.value});

  final int id;
  final String value;

  factory Model049.fromJson(Map<String, dynamic> json) =>
      _$Model049FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model049ToJson(this);
}
