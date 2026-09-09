import 'package:json_annotation/json_annotation.dart';

part 'model_297.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model297 {
  const Model297({required this.id, required this.value});

  final int id;
  final String value;

  factory Model297.fromJson(Map<String, dynamic> json) =>
      _$Model297FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model297ToJson(this);
}
