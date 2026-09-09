import 'package:json_annotation/json_annotation.dart';

part 'model_075.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model075 {
  const Model075({required this.id, required this.value});

  final int id;
  final String value;

  factory Model075.fromJson(Map<String, dynamic> json) =>
      _$Model075FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model075ToJson(this);
}
