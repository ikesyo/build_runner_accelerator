import 'package:json_annotation/json_annotation.dart';

part 'model_018.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model018 {
  const Model018({required this.id, required this.value});

  final int id;
  final String value;

  factory Model018.fromJson(Map<String, dynamic> json) =>
      _$Model018FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model018ToJson(this);
}
