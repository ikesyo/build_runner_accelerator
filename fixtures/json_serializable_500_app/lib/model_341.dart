import 'package:json_annotation/json_annotation.dart';

part 'model_341.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model341 {
  const Model341({required this.id, required this.value});

  final int id;
  final String value;

  factory Model341.fromJson(Map<String, dynamic> json) =>
      _$Model341FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model341ToJson(this);
}
